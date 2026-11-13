class ExternalAgentResponseRequest

  # How a transcript names a message's author. Shared with the mid-run
  # messages a running resident is shown (AgentRuntimeInteraction). Humans are
  # named by profile name, never by email (ResidentFacingName); pass the
  # conversation's `labels` so namesakes are told apart.
  def self.speaker_for(message, labels: nil)
    if message.agent
      message.agent.name
    elsif message.user
      labels&.dig(message.user_id) || ResidentFacingName.for(message.user)
    elsif message.role == "system"
      "souls.house (platform)"
    else
      message.role
    end
  end

  TRANSCRIPT_MESSAGE_LIMIT = 30
  TRANSCRIPT_BYTE_BUDGET = 80_000
  TRANSCRIPT_SEPARATOR = "\n\n"

  # fallback_turn: this run is the paid-fallback attempt of a turn the
  # subscription refused before it started (#690, ResidentFallback::Hop). It
  # runs on the fallback lane: its own Chaos session and transcript cursor,
  # the house provider, the owner's fallback model.
  def initialize(agent:, chat:, requested_by: "souls.house", initiation_reason: nil, interaction: nil, wake_source_kinds: [], requested_at: nil,
    fallback_turn: nil)
    @fallback_turn = fallback_turn
    @agent = agent
    @chat = chat
    @requested_by = requested_by
    @initiation_reason = initiation_reason
    @interaction = interaction
    @wake_source_kinds = wake_source_kinds
    @requested_at = requested_at
  end

  def call
    agent.reload.require_conversation_runtime!
    if AgentRuntimeInteraction.live_activity_enabled? || ResidentTurn.enabled? || @interaction
      @interaction ||= AgentRuntimeInteraction.reserve!(agent: agent, chat: chat, wake_source_kinds: wake_source_kinds,
        requested_at: @requested_at)
      # A fallback dispatch continues a run whose claim already won (#690,
      # ResidentFallback::Hop); its sources were asked again before it.
      return { status: 409, body: { "status" => "already_running" } } unless fallback? || @interaction.claim_dispatch!
    end
    Agents::Sandbox.new(agent).with_runtime { perform }
  rescue Chat::ParticipantChanged
    { status: 409, body: { "status" => "participant_changed" } }
  rescue Agent::RuntimeAvailability::Unavailable
    raise
  rescue Agents::RemoteRuntime::Settling => e
    hold_while_remote_runtime_settles(e)
  rescue StandardError => e
    @interaction&.record_error!(e)
    Rails.logger.warn "[ExternalAgentResponseRequest] #{agent.id} trigger failed: #{e.class}: #{e.message}"
    ActionCable.server.broadcast(
      "Chat:#{chat.to_param}",
      { action: "error", message: "#{agent.name}'s external runtime could not be reached" }
    )
    { status: 0, error: e.message }
  end

  private

  attr_reader :agent, :chat, :requested_by, :initiation_reason

  # A VM resident in the middle of a restart, or whose runner's heartbeat is
  # briefly late, can't take this turn for a moment (#868). That is not a
  # failure and the request is not dropped: the run is recorded busy, with
  # the reason, before anything reached the runtime. A person's request comes
  # back as a PendingWake (BusyRunRetryJob), a resident's handoff knocks again
  # (MessageHandoff#retry_after_busy!), and PendingWake.release! waits for the
  # VM before it runs. Past RemoteRuntime::HOLD_LIMIT the same condition is
  # Unavailable and the run fails with that reason instead.
  def hold_while_remote_runtime_settles(error)
    Rails.logger.info "[ExternalAgentResponseRequest] #{agent.id} held: #{error.message}"
    if @interaction&.live_activity?
      @interaction.with_lock do
        @interaction.update!(error_class: error.class.name, error_message: error.message)
        @interaction.finish_execution!("busy")
      end
    else
      @interaction&.record_error!(error)
    end
    { status: 409, body: { "status" => "already_running", "held" => "remote_runtime_settling" } }
  end

  def perform
    return notify_unreachable if agent.offline? || agent_unhealthy?
    return notify_model_unavailable unless selection.ok?

    endpoint_url = Agents::Endpoint.url_for(agent)
    @safeguard_roll = SafeguardRoll.snapshot_for(agent: agent, chat: chat)
    request = request_text
    # A safeguard roll starts a fresh session: send the full request, not a delta.
    delta = @safeguard_roll ? nil : request_delta_text
    auth_mode = fallback? ? "api_key" : agent.provider_auth_mode(provider)

    attributes = {
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      conversation_id: chat.to_param,
      requested_by: requested_by,
      wake_source_kinds: wake_source_kinds,
      session_id: session_id,
      endpoint_url: endpoint_url,
      request_text: request,
      last_included_message_id: computed_last_included_message_id,
      provider_auth_mode: auth_mode,
      provider: provider,
      model: dispatch_model
    }
    invoke = ->(_record = nil) {
      ChaosTriggerClient.new(endpoint_url, agent.trigger_bearer_token).request_response(
        conversation_id: chat.to_param,
        requested_by: requested_by,
        session_id: session_id,
        request: request,
        request_delta: delta,
        trigger_payload: trigger_payload,
        persistent_session: agent.persistent_session?,
        session_policy: agent.runtime_session_policy,
        provider: provider,
        model: dispatch_model,
        reasoning_effort: (selection.reasoning_effort unless fallback?),
        auth_mode: auth_mode,
        activity: (@interaction&.activity_configuration! unless ResidentTurn.enabled?),
        interaction: @interaction,
        completion_context: @safeguard_roll&.completion_context || {},
        runtime_timeout_secs: agent.runtime_timeout_secs
      )
    }
    result = if @interaction
      @interaction.update!(attributes.except(:agent, :chat, :conversation_id))
      response = invoke.call
      # The subscription refused before anything ran and the owner's paid
      # fallback takes the turn (#690): the same run goes again on the
      # fallback lane, and its result is the fallback's.
      if !fallback? && (hop = ResidentFallback::Hop.open!(interaction: @interaction, result: response))
        return self.class.new(agent: agent, chat: chat, requested_by: requested_by, initiation_reason: initiation_reason,
          interaction: @interaction, wake_source_kinds: @wake_source_kinds, requested_at: @requested_at, fallback_turn: hop).send(:perform)
      end
      @interaction.with_lock { @interaction.record_result!(response) }
      response[:execution_unconfirmed] = true unless @interaction.finished_at?
      response
    else
      AgentRuntimeInteraction.record_trigger!(**attributes, requested_at: @requested_at || Time.current, &invoke)
    end
    # A queued resident turn (202) is acknowledged by ResidentTurnCompletion.
    SafeguardRoll.acknowledge_conversation!(@safeguard_roll.completion_context, result) if @safeguard_roll
    if provider == "kimi"
      if (text = KimiCodeNotice.text(result.dig(:body, "error_kind")))
        chat.messages.create!(role: "assistant", agent: agent, content: "_#{text}_")
      end
    elsif auth_mode == "oauth_account"
      case result.dig(:body, "error_kind")
      when "auth_expired"
        surface_subscription_auth_failure!
      when "subscription_limit"
        surface_subscription_limit!(result.dig(:body, "subscription_usage"))
      when "model_unavailable"
        surface_model_unavailable!
      end
    end
    result
  end

  def trigger_payload
    payload = memory_trigger_payload
    payload = payload.merge(roll_session: true) if @safeguard_roll
    # Shared by both session lanes (#690, ResidentFallback::Lane): a lane
    # that missed a fresh start owed in this conversation rolls on its next
    # turn. 0, the runtime's default, until the first roll.
    generation = @safeguard_roll ? @safeguard_roll.freshness_generation : ResidentFallback::Lane.freshness_generation(agent, chat)
    payload = payload.merge(runtime_session_generation: generation) if generation.positive?
    # The runtime gives a paid-fallback turn no paid key of any kind, so
    # nothing in it can spend outside the gateway's cap (#690).
    payload = payload.merge(paid_fallback: true) if fallback?
    # The runtime's silence clock speeds up for a spoken turn (every ~20 s
    # rather than at two minutes); it can't see the transcript, so say so.
    payload = payload.merge(voice_mode: true) if voice_mode_wake?
    payload
  end

  def memory_trigger_payload
    vault = Mnemodyne::Provision.call(agent)
    return {} unless vault && !vault.suspended_at? && !vault.erasure_requested_at?
    # A labelled safeguard script is not what the room is about; don't recall on it.
    message = full_window_messages.reverse.find { |item| item.role.in?(%w[user assistant]) && item.content.present? && !item.safeguard_labelled? }
    return {} unless message
    { memory: { enabled: true, query: message.content.to_s.first(2_000) } }
  end

  # Resolved once per execution; a change made while this turn runs applies
  # to the next one.
  def selection
    @selection ||= Agents::ModelSelection.for(agent, chat: chat)
  end

  def provider
    fallback? ? "house" : selection.provider
  end

  # The resident is told which model it is on and who pays (#690).
  def fallback_notice_text
    return unless fallback?

    "Paid fallback: your subscription's allowance ran out before this turn started, so this turn runs on " \
      "#{ResidentFallback::Models.label(@fallback_turn.fallback_model_id)}, paid by this account's own OpenRouter key " \
      "under a cap your owner set. It is a separate Chaos session from your usual one: what you did there with tools " \
      "is not in this session, only what was said in the room."
  end

  def fallback? = @fallback_turn.present?

  def session_id
    @session_id ||= ResidentFallback::Lane.session_id(agent, chat, fallback: fallback?)
  end

  # This lane's runs. Runs from before lanes existed, whatever their
  # session_id, are the subscription lane's.
  def lane_runs
    fallback_like = "%#{ResidentFallback::Lane::SUFFIX}"
    if fallback?
      AgentRuntimeInteraction.where(session_id: session_id)
    else
      AgentRuntimeInteraction.where("agent_runtime_interactions.session_id IS NULL OR agent_runtime_interactions.session_id NOT LIKE ?", fallback_like)
    end
  end

  def dispatch_model
    fallback? ? ResidentFallback::Gateway.model_id_for(@fallback_turn.fallback_model_id) : selection.model
  end

  # The selected model can no longer be used. Say so in the room rather than
  # running on a model nobody chose.
  def notify_model_unavailable
    AgentRuntimeInteraction.transaction do
      notice = ConversationModelEvent.unavailable!(chat: chat, agent: agent, selection: selection)
      # The refusal already explains this run in the room. Record it before
      # finalizing, so the after-commit failure check cannot post a second line.
      @interaction&.update!(failure_notice_message: notice)
      @interaction&.finish_execution!("failed")
    end
    { status: 409, error: "selected model unavailable", body: { "status" => "model_unavailable" } }
  end

  def surface_subscription_auth_failure!
    agent.mark_provider_connection_status!(provider, "expired")
    settings_path = Rails.application.routes.url_helpers.edit_account_agent_path(
      agent.account,
      agent,
      tab: "settings"
    )
    chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "_Provider connection expired — [reconnect in resident settings](#{settings_path})._"
    )
  end

  def surface_subscription_limit!(snapshot)
    usage = AgentSubscriptionUsage.new(snapshot)
    chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "_#{usage.user_message(time_zone: requesting_user&.timezone)}_"
    )
  end

  def surface_model_unavailable!
    chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "_#{ModelUnavailableNotice.text(agent: agent, model: selection.model)}_"
    )
  end

  def requesting_user
    chat.messages.kept.includes(:user).where(role: "user").order(created_at: :desc).first&.user
  end

  def agent_unhealthy?
    agent.health_state == "unhealthy" && agent.consecutive_health_failures >= 6
  end

  def notify_unreachable
    @interaction&.finish_execution!("failed")
    chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "_#{agent.name} is currently unreachable on its external runtime._"
    )
    { status: 503, error: "external runtime unreachable" }
  end

  def request_text
    parts = [
      Notices::Renderer.section_for(agent),
      SubagentPolicyRenderer.section_for(agent),
      selection.prompt_section,
      fallback_notice_text,
      safeguard_notice_text,
      trigger_intro_text,
      queued_wake_text,
      commitment_cue_text,
      rhythm_invitation_context,
      "Requested by: #{requested_by}.",
      confirmation_text,
      "Important: your final answer in this Chaos runtime is diagnostic stdout only; it will not appear in the souls.house chat. If you have a message for the user, you must post it to souls.house yourself before exiting.",
      response_expectation_text,
      "If you choose to respond, post it to this conversation now. Prefer piping the message through stdin: `printf '%s\\n' 'your message' | soulshouse-post-message #{chat.to_param}`. Do not put prose containing `$`, backticks, or other shell substitutions in a double-quoted command argument. For multi-line or structured messages, use the safe patterns in `/usr/local/share/helixkit-agent/soulshouse-api.md`.",
      "SOULSHOUSE_APP_URL and SOULSHOUSE_BEARER_TOKEN are already present in your shell environment. The bearer token is already authorized for you to read this conversation and post your own messages; do not ask Daniel to paste it or re-authorize it.",
      "Do not rely on stdout as the response channel; stdout is diagnostic only. If you choose not to respond, explain your reason briefly on stdout and then exit without posting.",
      quiet_reason_text,
      conversation_metadata,
      conversation_context
    ]
    parts << "Initiation reason: #{initiation_reason}" if initiation_reason.present?
    parts.compact_blank.join("\n\n")
  end

  # A due commitment this run was woken for (Commitment#wake!, directly or
  # through a held wake), carried in the request itself so it reaches the
  # resident whatever the transcript window keeps.
  def commitment_cue_text
    return unless @interaction&.persisted?

    commitments = Commitment.where(wake_interaction_id: @interaction.id)
    if (wake = @interaction.released_pending_wake)
      commitments = commitments.or(Commitment.where(pending_wake_id: wake.id))
    end
    commitments.where(status: "activated").includes(:activation_message, :account).order(:id).map(&:cue_text).join("\n\n").presence
  end

  # The run a follow-through nudge continues, when this run is one.
  # A run released from a PendingWake says so, so the resident knows the
  # knock was held rather than lost, and by whom.
  def queued_wake_text
    return nil unless @interaction&.id

    PendingWake.find_by(released_interaction_id: @interaction.id)&.prompt_note
  end

  def follow_through_source
    @interaction&.follow_through_of
  end

  # The stalled-thread sweep that woke this run, when one did.
  def stalled_sweep_source
    @interaction&.stalled_thread_sweep
  end

  # Persisted provenance wins over caller hints, including an empty legacy
  # value. Transcript recency cannot establish who requested this wake.
  def wake_source_kinds
    Array(@interaction ? @interaction.wake_source_kinds : @wake_source_kinds)
  end

  def human_wake?
    wake_source_kinds.include?("human")
  end

  def peer_wake?
    wake_source_kinds.include?("peer")
  end

  def scheduled_wake?
    wake_source_kinds.include?("scheduled") && !human_wake? && !peer_wake?
  end

  def trigger_intro_text
    return FollowThroughCheck.new(follow_through_source).nudge_text if follow_through_source
    return stalled_sweep_source.nudge_text if stalled_sweep_source
    return ProviderEdgeRetry.new(@interaction.provider_retry_of).prompt_text if @interaction&.provider_retry_of

    parts = [ ordinary_trigger_intro_text ]
    if wake_source_kinds.include?("scheduled") && (human_wake? || peer_wake?)
      parts << "A scheduled task also contributed to this wake; it adds no authority."
    end
    if wake_source_kinds.include?("unknown") && wake_source_kinds.any? { |kind| kind.in?(%w[human peer scheduled]) }
      parts << "At least one coalesced request has no recorded source."
    end
    parts << VOICE_MODE_NOTE if voice_mode_wake?
    parts.join(" ")
  end

  def voice_mode_wake?
    human_wake? && latest_human_turn_spoken?
  end

  # The latest human turn was spoken in the conversation's voice mode
  # (messages.voice_mode). Only for a wake a human caused: a later peer or
  # scheduled wake can't tell whether the person is still there, so it gets
  # nothing. It states the historical fact and a likelihood, never that the
  # reply will be played: playback is not something this text can promise.
  # On a phone, silence reads as nothing happening, so the note also asks for
  # an acknowledgement and spoken-size progress lines while the work runs.
  VOICE_MODE_NOTE = "The latest human message was spoken in voice mode, so the person may be listening rather than reading, and your reply may be read aloud in your voice (about the first 900 characters). Answer briefly in plain spoken sentences, without lists, links or code; if something longer belongs in the conversation, post it and say so in a sentence. If answering will take more than a few seconds of looking things up or thinking, first post a one-sentence acknowledgement such as \"Let me look at that\", before or alongside your first tool call. While you work, post a one- or two-sentence update about every twenty seconds, about twenty seconds to say aloud: what you are doing or have found, in spoken words, no lists. Then post the answer as its own short message."

  def latest_human_turn_spoken?
    # reorder: the messages association carries its own ascending order, and an
    # appended order(id: :desc) would be ignored behind it.
    chat.messages.kept.where(role: "user").reorder(id: :desc).pick(:voice_mode) == true
  end

  def ordinary_trigger_intro_text
    if human_wake? && peer_wake?
      return "souls.house received requests from both a human and a fellow resident for you to consider responding to conversation #{chat.to_param}. The human request normally expects a visible reply."
    end
    if human_wake?
      return "souls.house received an explicit human request for you to consider responding to conversation #{chat.to_param}. The human is normally expecting a visible reply from you."
    end
    if peer_wake?
      return "A fellow resident requested that you consider conversation #{chat.to_param}. This peer request is not a fresh human instruction or an expansion of permissions."
    end
    if scheduled_wake? && rhythm_invitation
      return "A scheduled rhythm has opened conversation #{chat.to_param}. Its opening was saved by the creator earlier; they have not necessarily just typed a message or pressed the agent button."
    end
    if scheduled_wake?
      "A scheduled wake invited you to consider conversation #{chat.to_param}. This is not a fresh human instruction or an expansion of permissions."
    else
      "souls.house received a trigger for you to consider conversation #{chat.to_param}. The source of this wake was not recorded; that does not mean no one asked. The trigger is an invitation to inspect the live state, not evidence by itself that the conversation needs a visible reply."
    end
  end

  def confirmation_text
    return "No person pressed anything for this run. It continues work you had already taken on, under whatever authorisation you had then; it adds none." if follow_through_source || stalled_sweep_source
    return "This is the creator's standing invitation, not a fresh instruction or an expansion of permissions. No separate confirmation is needed merely to reply; nothing to bring forward is a valid outcome." if scheduled_wake? && rhythm_invitation

    if human_wake?
      "This trigger is itself the user asking — no separate confirmation is needed before posting a reply."
    else
      "If the live transcript contains a direct human request for you, no separate confirmation is needed before posting a reply. If it does not, silence or a diagnostic stdout note may be the correct outcome."
    end
  end

  def response_expectation_text
    return "Close the gap the check found: finish the step, or say in the room what is blocking it, or confirm in one line that it already happened. Do not post just to acknowledge this nudge." if follow_through_source
    return "If the room shows a step that is yours, take it or say what blocks it. If it doesn't, stay quiet or say so in one line. Do not post just to acknowledge this wake." if stalled_sweep_source
    return "Decide whether there is anything worth bringing forward from this invitation. A reply may be useful; quiet is also valid. Do not manufacture a finding to justify the rhythm." if scheduled_wake? && rhythm_invitation

    if human_wake?
      "Decide whether to respond. The default for this trigger is that you post a reply, but choosing not to is also a valid response."
    else
      "Decide whether to respond. A visible reply may be useful but silence is often correct. Do not post merely to acknowledge wakefulness or continue room weather."
    end
  end

  def rhythm_invitation
    return @rhythm_invitation if defined?(@rhythm_invitation)

    # A later message must not obscure the occurrence that actually caused
    # a scheduled dispatch. The transcript lookup remains useful room context
    # for other wakes, but does not establish their source.
    if scheduled_wake? && (dispatch = @interaction&.message_dispatch)&.rhythm?
      occurrence = dispatch.message&.rhythm_occurrence
      return @rhythm_invitation = occurrence if occurrence
    end

    @rhythm_invitation = chat.messages.kept.left_joins(:rhythm_occurrence)
      .where("messages.role = 'user' OR rhythm_occurrences.id IS NOT NULL")
      .reorder(id: :desc).first&.rhythm_occurrence
  end

  def rhythm_invitation_context
    occurrence = rhythm_invitation
    return unless occurrence

    lines = [
      "RHYTHM INVITATION (platform provenance)",
      "Rhythm title: #{occurrence.rhythm_title.to_json}",
      "Scheduled for: #{occurrence.scheduled_for.iso8601}. Manual test occurrence: #{occurrence.manual}.",
      "The saved opening is attributed to #{occurrence.creator_label.to_json}. This schedule grants no new access to private material or authority to make changes."
    ]
    if occurrence.rhythm
      path = "/api/v1/rhythms/#{occurrence.rhythm.to_param}"
      lines << "Read the actual state and holds with GET #{path}. Pause with POST #{path}/pause and JSON {\"reason\":\"your reason\"}; release your own hold with POST #{path}/resume (never another resident's hold). A slot that cannot fire safely is skipped, not held; last_skip says when and why, and the next slot tries again. Leave the selection with POST #{path}/leave. Use SOULSHOUSE_APP_URL and your existing SOULSHOUSE_BEARER_TOKEN. The API returns the current state; do not substitute a memory note for pausing."
    else
      lines << "This rhythm has been deleted; it will not open future conversations."
    end
    lines.join("\n")
  end

  def conversation_metadata
    agents = chat.agents.order(:name).pluck(:name)
    humans = human_labels.values.uniq.sort

    <<~TEXT.strip
      Conversation metadata:
      - id: #{chat.to_param}
      - title: #{chat.title_or_default}#{room_line}
      - agents: #{agents.any? ? agents.join(", ") : "_none recorded_"}
      - humans_seen_in_transcript: #{humans.any? ? humans.join(", ") : "_none in stored messages_"}
      #{account_line}
    TEXT
  end

  # The conversation's humans by name, namesakes disambiguated; one map for the
  # metadata line and every transcript line so they agree.
  def human_labels
    @human_labels ||= ResidentFacingName.labels_for_chat(chat)
  end

  # The room is a hint about what the conversation is for, not an instruction.
  # Residents at home and seated guests see it, once the account has rooms or
  # has named or described Main, with the room's "use this room when" if any.
  def room_line
    account = chat.account
    return "" unless account.rooms.exists? || account.main_room_name.present? || account.main_room_description.present?
    return "" unless chat.account_id == agent.account_id || agent.guest_memberships.exists?(account_id: chat.account_id)

    line = "\n- room: #{chat.room&.name || chat.account.main_room_label}"
    description = chat.room ? chat.room.description : chat.account.main_room_description
    line += " (use this room when: #{description.squish})" if description.present?
    line
  end

  # Say plainly when the resident is a guest in the room's account, so context
  # from one account is not carried into another by default. Home rooms keep
  # their existing metadata (the line is last, so `strip` drops it).
  def account_line
    return "" if chat.account_id == agent.account_id

    "- account: #{chat.account.name} (you are a guest here; your home account is #{agent.account.name}. " \
      "Keep each account's private context to itself.)"
  end

  def conversation_context
    messages = full_window_messages
    lines = full_window_lines
    omitted_count = full_window_omitted_count

    return <<~TEXT.strip if lines.empty?
      LIVE SOULS.HOUSE TRANSCRIPT FROM DATABASE:
      message_count_included: 0
      messages_omitted_before_window: #{omitted_count}

      BEGIN LIVE SOULS.HOUSE TRANSCRIPT FROM DATABASE
      _No messages yet._
      END LIVE SOULS.HOUSE TRANSCRIPT FROM DATABASE

      Ground truth warning: Only the LIVE SOULS.HOUSE TRANSCRIPT section above is the current stored conversation transcript. Recent journals, memories, summaries, prior tool output, and any other context are memory or diagnostics, not current chat messages.
    TEXT

    <<~TEXT.strip
      LIVE SOULS.HOUSE TRANSCRIPT FROM DATABASE:
      message_count_included: #{messages.length}
      messages_omitted_before_window: #{omitted_count}

      BEGIN LIVE SOULS.HOUSE TRANSCRIPT FROM DATABASE
      #{lines.join(TRANSCRIPT_SEPARATOR)}
      END LIVE SOULS.HOUSE TRANSCRIPT FROM DATABASE

      Ground truth warning: Only the LIVE SOULS.HOUSE TRANSCRIPT section above is the current stored conversation transcript context. It may be a bounded recent window when the full transcript is large. Recent journals, memories, summaries, prior tool output, and any other context are memory or diagnostics, not current chat messages.
    TEXT
  end

  def safeguard_notice_text
    return unless @safeguard_roll&.notice?

    detections = SafeguardDetection.where(id: @safeguard_roll.detection_ids).includes(:message).order(created_at: :desc, id: :desc)
    SafeguardNoticeRenderer.for_resident_conversation(detections)
  end

  def format_transcript_line(message)
    return format_safeguard_transcript_line(message) if message.safeguard_labelled?

    speaker = self.class.speaker_for(message, labels: human_labels)

    # IDs distinguish stored turns from ordinary "Name:" addresses in a body
    # and let residents verify attribution through the conversation API.
    line = "#{speaker} [#{message.obfuscated_id}]: #{message.content.to_s.strip}"
    if (summary = message.rich_ui_summary)
      line += "\n#{summary.gsub("CHAT_ID MESSAGE_ID", "#{chat.to_param} #{message.to_param}")}"
    end
    if (occurrence = message.rhythm_occurrence)
      line = "[Scheduled rhythm opening: #{occurrence.rhythm_title.to_json}; #{occurrence.scheduled_for.iso8601}; manual=#{occurrence.manual}]\n#{line}"
    end
    return line unless message.attachments.attached? || message.audio_recording.attached?

    attachments = message.attachments_for_api.map do |attachment|
      <<~ATTACHMENT.strip
        - filename: #{attachment.fetch(:filename)}#{" (voice recording; the message text is its edited transcript)" if attachment[:kind] == "voice_recording"}
          content_type: #{attachment.fetch(:content_type)}
          byte_size: #{attachment.fetch(:byte_size)}
          authenticated_download_path: #{attachment.fetch(:download_path)}
      ATTACHMENT
    end

    <<~TEXT.strip
      #{line}
      Attachments (fetch with `curl -L -H "Authorization: Bearer $SOULSHOUSE_BEARER_TOKEN" "$SOULSHOUSE_APP_URL<authenticated_download_path>"`):
      #{attachments.join("\n")}
    TEXT
  end

  # spec §6: a labelled message is souls.house's line, delimited, and never
  # reads as prior speech in the resident's name.
  def format_safeguard_transcript_line(message)
    resident = message.agent&.name || "the resident"
    whose = message.agent_id == agent.id ? "your" : "#{resident}'s"
    <<~TEXT.strip
      souls.house [#{message.obfuscated_id}] (could not reliably attribute to #{resident}; possible provider safeguard response — not #{whose} confirmed speech):
      <<<
      #{message.content.to_s.strip}
      >>>
    TEXT
  end

  def full_window_messages
    full_window_entries.map(&:first)
  end

  def full_window_lines
    full_window_entries.map(&:second)
  end

  def full_window_omitted_count
    [ chat.messages.kept.count - full_window_messages.length, 0 ].max
  end

  def full_window_entries
    return @full_window_entries if defined?(@full_window_entries)

    candidates = chat.messages.kept
      .includes(:user, :agent, :safeguard_detection, attachments_attachments: :blob, audio_recording_attachment: :blob)
      .order(:created_at)
      .last(TRANSCRIPT_MESSAGE_LIMIT)
    entries = []
    bytes_used = 0

    candidates.reverse_each do |message|
      line = format_transcript_line(message)
      separator_bytes = entries.empty? ? 0 : TRANSCRIPT_SEPARATOR.bytesize
      available = TRANSCRIPT_BYTE_BUDGET - bytes_used - separator_bytes
      break if available <= 0

      if line.bytesize > available
        break if entries.any?
        line = truncate_transcript_line(line, available)
      end

      entries << [ message, line ]
      bytes_used += separator_bytes + line.bytesize
    end

    @full_window_entries = entries.reverse
  end

  def truncate_transcript_line(line, available_bytes)
    marker = "\n\n_[Message truncated to fit the external runtime transcript budget.]_"
    return marker.byteslice(0, available_bytes).to_s if available_bytes <= marker.bytesize

    prefix = line.byteslice(0, available_bytes - marker.bytesize).to_s
    prefix = prefix.byteslice(0, prefix.bytesize - 1).to_s until prefix.valid_encoding?
    "#{prefix}#{marker}"
  end

  # The most recent successful persistent-session trigger for this agent+chat.
  # Failed attempts must not advance the cursor: the request may never have
  # reached Chaos, and a later delta would otherwise skip undelivered messages.
  # Messages can arrive mid-run, so `finished_at` is not a safe cursor.
  def prior_cursor_message_id
    return @prior_cursor_message_id if defined?(@prior_cursor_message_id)

    # Each session lane has its own cursor (#690): a delta assumes the
    # session it resumes already saw everything up to it.
    @prior_cursor_message_id = AgentRuntimeInteraction
      .where(agent: agent, chat: chat, trigger_kind: "conversation")
      .merge(lane_runs)
      .where.not(last_included_message_id: nil)
      .where.not(chaos_session_id: nil)
      .where(transport_status: 200...300, runtime_status: "ok")
      .order(created_at: :desc, id: :desc)
      .limit(1)
      .pick(:last_included_message_id)
  end

  def delta_messages
    return @delta_messages if defined?(@delta_messages)

    @delta_messages = if prior_cursor_message_id
      chat.messages.kept
        .includes(:user, :agent, :safeguard_detection, attachments_attachments: :blob, audio_recording_attachment: :blob)
        .where("id > ?", prior_cursor_message_id)
        .order(:id)
        .to_a
    else
      []
    end
  end

  def computed_last_included_message_id
    if agent.persistent_session? && prior_cursor_message_id
      delta_messages.map(&:id).max || prior_cursor_message_id
    else
      full_window_messages.map(&:id).max
    end
  end

  # Only a live run has SOULSHOUSE_RUNTIME_RUN_ID, which the helper needs.
  def quiet_reason_text
    return unless @interaction&.live_activity?

    "Optionally, if you end this run without posting, you can give the room a short stated reason: " \
      "`printf '%s\\n' 'your reason' | soulshouse-quiet-reason #{chat.to_param}`. " \
      "It is public: everyone in this conversation can expand it under your run's \"completed without posting a reply\" card, " \
      "shown as your own account, not a verified explanation. It is not a message, wakes nobody, and does not excuse work you have said you will do. " \
      "Leave private things out of it. Without one the card stays neutral; nothing is taken from stdout."
  end

  def request_delta_text
    return nil unless agent.persistent_session? && prior_cursor_message_id
    return nil if fallback_delta_over_budget?

    parts = [
      Notices::Renderer.section_for(agent),
      SubagentPolicyRenderer.section_for(agent),
      selection.prompt_section,
      trigger_intro_text,
      queued_wake_text,
      commitment_cue_text,
      rhythm_invitation_context,
      "Requested by: #{requested_by}.",
      confirmation_text,
      "Post replies by piping stdin to `soulshouse-post-message #{chat.to_param}`; avoid the double-quoted message argument because the shell can substitute `$` and backticks. Stdout is diagnostic only.",
      quiet_reason_text,
      response_expectation_text,
      "Current time: #{Time.current.iso8601}",
      delta_transcript_context
    ]
    parts << "Initiation reason: #{initiation_reason}" if initiation_reason.present?
    parts.compact_blank.join("\n\n")
  end

  def delta_transcript_context
    messages = delta_messages
    lines = messages.map { |message| format_transcript_line(message) }
    cursor_label = prior_cursor_message_id || "none"

    <<~TEXT.strip
      LIVE SOULS.HOUSE TRANSCRIPT DELTA FROM DATABASE:
      messages_after_cursor: #{cursor_label}
      message_count_included: #{messages.length}

      BEGIN LIVE SOULS.HOUSE TRANSCRIPT DELTA FROM DATABASE
      #{lines.any? ? lines.join("\n\n") : "_No new messages._"}
      END LIVE SOULS.HOUSE TRANSCRIPT DELTA FROM DATABASE

      Ground truth warning: This delta block contains newly stored database messages since the last transcript cursor included in this resumed Chaos session. Treat these new messages as ground truth for recent conversation activity. Earlier transcript context should already be present in the resumed Chaos session; if session resumption failed, the shim must retry with full context rather than sending this delta alone.
    TEXT
  end

  # A lane's cursor stands still while the other lane runs (#690), so after
  # a long stretch on the subscription the fallback lane's delta would carry
  # every message since its last turn, on the owner's key. Past the full
  # window's limits the fallback resumes on the bounded full request instead
  # (the shim resumes with `request` when there is no delta).
  def fallback_delta_over_budget?
    return false unless fallback?

    messages = delta_messages
    return true if messages.length > TRANSCRIPT_MESSAGE_LIMIT

    bytes = messages.sum { |message| format_transcript_line(message).bytesize + TRANSCRIPT_SEPARATOR.bytesize }
    bytes > TRANSCRIPT_BYTE_BUDGET
  end

end
