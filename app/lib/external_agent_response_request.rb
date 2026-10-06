class ExternalAgentResponseRequest

  TRANSCRIPT_MESSAGE_LIMIT = 30
  TRANSCRIPT_BYTE_BUDGET = 80_000
  TRANSCRIPT_SEPARATOR = "\n\n"

  def initialize(agent:, chat:, requested_by: "souls.house", initiation_reason: nil, interaction: nil)
    @agent = agent
    @chat = chat
    @requested_by = requested_by
    @initiation_reason = initiation_reason
    @interaction = interaction
  end

  def call
    agent.reload.require_conversation_runtime!
    if AgentRuntimeInteraction.live_activity_enabled? || ResidentTurn.enabled? || @interaction
      @interaction ||= AgentRuntimeInteraction.reserve!(agent: agent, chat: chat)
      return { status: 409, body: { "status" => "already_running" } } unless @interaction.claim_dispatch!
    end
    Agents::Sandbox.new(agent).with_runtime { perform }
  rescue Agent::RuntimeAvailability::Unavailable
    raise
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

  def perform
    return notify_unreachable if agent.offline? || agent_unhealthy?

    endpoint_url = Agents::Endpoint.url_for(agent)
    session_id = "#{agent.uuid}-#{chat.id}"
    request = request_text
    delta = request_delta_text
    auth_mode = agent.provider_auth_mode(provider)

    attributes = {
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      conversation_id: chat.to_param,
      requested_by: requested_by,
      session_id: session_id,
      endpoint_url: endpoint_url,
      request_text: request,
      last_included_message_id: computed_last_included_message_id,
      provider_auth_mode: auth_mode
    }
    invoke = -> {
      ChaosTriggerClient.new(endpoint_url, agent.trigger_bearer_token).request_response(
        conversation_id: chat.to_param,
        requested_by: requested_by,
        session_id: session_id,
        request: request,
        request_delta: delta,
        trigger_payload: memory_trigger_payload,
        persistent_session: agent.persistent_session?,
        session_policy: agent.runtime_session_policy,
        provider: provider,
        model: Agents::Sandbox.chaos_model_for(agent),
        reasoning_effort: agent.reasoning_effort,
        auth_mode: auth_mode,
        activity: (@interaction&.activity_configuration! unless ResidentTurn.enabled?),
        interaction: @interaction,
        runtime_timeout_secs: agent.runtime_timeout_secs
      )
    }
    result = if @interaction
      @interaction.update!(attributes.except(:agent, :chat, :conversation_id))
      response = invoke.call
      @interaction.with_lock { @interaction.record_result!(response) }
      response[:execution_unconfirmed] = true unless @interaction.finished_at?
      response
    else
      AgentRuntimeInteraction.record_trigger!(**attributes, &invoke)
    end
    if auth_mode == "oauth_account"
      case result.dig(:body, "error_kind")
      when "auth_expired"
        surface_subscription_auth_failure!
      when "subscription_limit"
        surface_subscription_limit!(result.dig(:body, "subscription_usage"))
      end
    end
    result
  end

  def memory_trigger_payload
    vault = Mnemodyne::Provision.call(agent)
    return {} unless vault && !vault.suspended_at? && !vault.erasure_requested_at?
    message = full_window_messages.reverse.find { |item| item.role.in?(%w[user assistant]) && item.content.present? }
    return {} unless message
    { memory: { enabled: true, query: message.content.to_s.first(2_000) } }
  end

  def provider
    @provider ||= Agents::Sandbox.chaos_provider_for(agent)
  end

  def surface_subscription_auth_failure!
    agent.mark_provider_connection_status!(provider, "expired")
    settings_path = Rails.application.routes.url_helpers.edit_account_agent_path(
      agent.account,
      agent,
      tab: "hosting"
    )
    chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "_Provider connection expired — [reconnect in agent hosting settings](#{settings_path})._"
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
      trigger_intro_text,
      rhythm_invitation_context,
      "Requested by: #{requested_by}.",
      confirmation_text,
      "Important: your final answer in this Chaos runtime is diagnostic stdout only; it will not appear in the souls.house chat. If you have a message for the user, you must post it to souls.house yourself before exiting.",
      response_expectation_text,
      "If you choose to respond, post it to this conversation now. Prefer piping the message through stdin: `printf '%s\\n' 'your message' | soulshouse-post-message #{chat.to_param}`. Do not put prose containing `$`, backticks, or other shell substitutions in a double-quoted command argument. For multi-line or structured messages, use the safe patterns in `/usr/local/share/helixkit-agent/soulshouse-api.md`.",
      "SOULSHOUSE_APP_URL and SOULSHOUSE_BEARER_TOKEN are already present in your shell environment. The bearer token is already authorized for you to read this conversation and post your own messages; do not ask Daniel to paste it or re-authorize it.",
      "Do not rely on stdout as the response channel; stdout is diagnostic only. If you choose not to respond, explain your reason briefly on stdout and then exit without posting.",
      conversation_metadata,
      conversation_context
    ]
    parts << "Initiation reason: #{initiation_reason}" if initiation_reason.present?
    parts.compact_blank.join("\n\n")
  end

  def trigger_intro_text
    if rhythm_invitation
      return "A scheduled rhythm has opened conversation #{chat.to_param}. Its opening was saved by the creator earlier; they have not necessarily just typed a message or pressed the agent button."
    end
    if recent_human_message?
      "souls.house received an explicit user request for you to consider responding to conversation #{chat.to_param}. The user pressed the agent button, so they are normally expecting a visible reply from you."
    else
      "souls.house received a trigger for you to consider conversation #{chat.to_param}. In this no-recent-human-message context, the trigger is an invitation to inspect the live state, not evidence by itself that the conversation needs a visible reply."
    end
  end

  def confirmation_text
    return "This is the creator's standing invitation, not a fresh instruction or an expansion of permissions. No separate confirmation is needed merely to reply; nothing to bring forward is a valid outcome." if rhythm_invitation

    if recent_human_message?
      "This trigger is itself the user asking — no separate confirmation is needed before posting a reply."
    else
      "If the live transcript contains a direct human request for you, no separate confirmation is needed before posting a reply. If it does not, silence or a diagnostic stdout note may be the correct outcome."
    end
  end

  def response_expectation_text
    return "Decide whether there is anything worth bringing forward from this invitation. A reply may be useful; quiet is also valid. Do not manufacture a finding to justify the rhythm." if rhythm_invitation

    if recent_human_message?
      "Decide whether to respond. The default for this trigger is that you post a reply, but choosing not to is also a valid response."
    else
      "Decide whether to respond. This is a no-recent-human-message context, so a visible reply may be useful but silence is often correct. Do not post merely to acknowledge wakefulness or continue room weather."
    end
  end

  def recent_human_message?
    chat.messages.kept.where(role: "user").where("created_at > ?", 12.hours.ago).exists?
  end

  def rhythm_invitation
    return @rhythm_invitation if defined?(@rhythm_invitation)

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
      lines << "Read the actual state and holds with GET #{path}. Pause with POST #{path}/pause and JSON {\"reason\":\"your reason\"}; release your own hold with POST #{path}/resume (creators may also release corrected system holds, never another resident's hold). Leave the selection with POST #{path}/leave. Use SOULSHOUSE_APP_URL and your existing SOULSHOUSE_BEARER_TOKEN. The API returns the current state; do not substitute a memory note for pausing."
    else
      lines << "This rhythm has been deleted; it will not open future conversations."
    end
    lines.join("\n")
  end

  def conversation_metadata
    agents = chat.agents.order(:name).pluck(:name)
    humans = chat.messages.kept.includes(:user).where(role: "user").filter_map { |message| message.user&.email_address }.uniq.sort

    <<~TEXT.strip
      Conversation metadata:
      - id: #{chat.to_param}
      - title: #{chat.title_or_default}
      - agents: #{agents.any? ? agents.join(", ") : "_none recorded_"}
      - humans_seen_in_transcript: #{humans.any? ? humans.join(", ") : "_none in stored messages_"}
      #{account_line}
    TEXT
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

  def format_transcript_line(message)
    speaker = if message.agent
      message.agent.name
    elsif message.user
      message.user.email_address
    else
      message.role
    end

    # IDs distinguish stored turns from ordinary "Name:" addresses in a body
    # and let residents verify attribution through the conversation API.
    line = "#{speaker} [#{message.obfuscated_id}]: #{message.content.to_s.strip}"
    if (occurrence = message.rhythm_occurrence)
      line = "[Scheduled rhythm opening: #{occurrence.rhythm_title.to_json}; #{occurrence.scheduled_for.iso8601}; manual=#{occurrence.manual}]\n#{line}"
    end
    return line unless message.attachments.attached?

    attachments = message.attachments_for_api.map do |attachment|
      <<~ATTACHMENT.strip
        - filename: #{attachment.fetch(:filename)}
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
      .includes(:user, :agent, attachments_attachments: :blob)
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

    @prior_cursor_message_id = AgentRuntimeInteraction
      .where(agent: agent, chat: chat, trigger_kind: "conversation")
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
        .includes(:user, :agent, attachments_attachments: :blob)
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

  def request_delta_text
    return nil unless agent.persistent_session? && prior_cursor_message_id

    parts = [
      Notices::Renderer.section_for(agent),
      SubagentPolicyRenderer.section_for(agent),
      trigger_intro_text,
      rhythm_invitation_context,
      "Requested by: #{requested_by}.",
      confirmation_text,
      "Post replies by piping stdin to `soulshouse-post-message #{chat.to_param}`; avoid the double-quoted message argument because the shell can substitute `$` and backticks. Stdout is diagnostic only.",
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

end
