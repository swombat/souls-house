module AgentRuntimeInteraction::LiveActivity

  extend ActiveSupport::Concern

  TERMINAL_STATES = %w[completed failed timed_out cancelled busy outcome_unknown].freeze
  PREPARATION_WINDOW = 10.minutes
  RELEASE_GRACE = 10.minutes

  included do
    has_many :agent_runtime_attempts, dependent: :destroy
    has_many :linked_messages, class_name: "Message", foreign_key: :runtime_interaction_id, dependent: :nullify
    attr_accessor :enqueue_dispatch
    belongs_to :message_dispatch, optional: true
    has_one :released_pending_wake, class_name: "PendingWake", foreign_key: :released_interaction_id, inverse_of: :released_interaction
    has_many :message_handoffs, foreign_key: :runtime_interaction_id, inverse_of: :runtime_interaction
    after_create_commit :enqueue_live_dispatch, if: :enqueue_dispatch
  end

  class_methods do
    def live_activity_enabled?
      ENV.fetch("SOULSHOUSE_LIVE_ACTIVITY", "1") != "0"
    end

    # A deadline (a message dispatch's expiry) caps the preparation window, so
    # a run reserved late cannot start later than its request allowed.
    def reserve!(agent:, chat:, enqueue: false, response_chain_agent_ids: [], message_dispatch: nil, deadline: nil, follow_through_of: nil)
      chat.with_lock do
        raise ArgumentError, "Conversation unavailable" unless chat.respondable? && chat.manual_responses? && chat.agents.exists?(agent.id)
        agent.reload.require_conversation_runtime!
        chat.agent_runtime_interactions.where(agent: agent, finished_at: nil).each(&:reconcile_activity!)
        raise Chat::AlreadyResponding, "#{agent.name} is already responding" if chat.agent_response_active?(agent)

        agent.with_lock do
          raise Agent::RuntimeAvailability::Unavailable, "Resident backup is pending" if Backup::VmResident.held?(agent)
          create!(
            agent: agent, chat: chat, trigger_kind: "conversation",
            conversation_obfuscated_id: chat.to_param, requested_by: "souls.house",
            session_id: "#{agent.uuid}-#{chat.id}", started_at: Time.current,
            run_id: SecureRandom.uuid, execution_state: "queued",
            execution_deadline_at: [ PREPARATION_WINDOW.from_now, deadline ].compact.min,
            message_dispatch: message_dispatch,
            narration_shared: agent.share_working_narration?,
            response_chain_agent_ids: response_chain_agent_ids,
            follow_through_of: follow_through_of,
            enqueue_dispatch: enqueue
          )
        end
      end
    end
  end

  def live_activity?
    run_id.present?
  end

  # A run a human message asked for may start only while that request still
  # stands: not discarded, author still a member, live activity still on.
  # Checked here, under the dispatch lock, because anything can change while
  # the run is queued. Once a claim wins, the run may reach the runtime and
  # nothing here can recall it.
  def claim_dispatch!
    return claim_released_wake! if released_pending_wake
    return claim_handoff! if message_handoffs.exists?
    return claim_dispatch_unchecked! unless message_dispatch

    message_dispatch.with_lock do
      next claim_dispatch_unchecked! if message_dispatch.deliverable!

      with_lock { finish_execution!("cancelled") if dispatch_claimed_at.nil? }
      false
    end
  end

  # A run released from a PendingWake starts only if the wake would still be
  # released now (PendingWake#claim_refusal_reason), checked under the wake's
  # lock. Lock order: wake, then this interaction.
  def claim_released_wake!
    wake = released_pending_wake
    wake.with_lock do
      reason = wake.claim_refusal_reason
      next claim_dispatch_unchecked! unless reason

      # A run already claimed (a duplicate delivery) is left alone.
      refused = with_lock do
        next false unless dispatch_claimed_at.nil? && !execution_state.in?(TERMINAL_STATES)

        finish_execution!("cancelled")
        true
      end
      wake.update!(dropped_at: Time.current, drop_reason: "claim_refused:#{reason}") if refused
      false
    end
  end

  # A run a resident's handoff woke at once (MessageHandoff#dispatch!) starts
  # only while the request still stands, as a held one's release would:
  # message kept, author and recipient still in the room, recipient not
  # paused. Checked under the rows a withdrawal writes
  # (MessageHandoff#claim_refusal_reason), then this interaction.
  def claim_handoff!
    handoffs = message_handoffs.order(:id).to_a
    MessageHandoff.transaction do
      reasons = handoffs.map(&:claim_refusal_reason)
      next claim_dispatch_unchecked! if reasons.any?(&:nil?)

      refused = with_lock do
        next false unless dispatch_claimed_at.nil? && !execution_state.in?(TERMINAL_STATES)

        finish_execution!("cancelled")
        true
      end
      handoffs.zip(reasons).each { |handoff, reason| handoff.refuse_claim!(reason) } if refused
      false
    end
  end

  def claim_dispatch_unchecked!
    with_lock do
      reconcile_activity!
      return false unless execution_state == "queued" && dispatch_claimed_at.nil?

      update!(dispatch_claimed_at: Time.current, execution_state: "preparing")
      true
    end
  end

  def activity_configuration!
    with_lock { prepare_activity_configuration! }
  end

  def prepare_activity_configuration!
    raise ArgumentError, "Runtime preparation expired" unless execution_state == "preparing" && execution_deadline_at&.future?

    token = SecureRandom.hex(32)
    # Resume and fresh fallback share one turn budget, with reporting grace.
    deadline = (agent.runtime_timeout_secs + 30).seconds.from_now
    update!(
      execution_deadline_at: deadline,
      activity_token_digest: Digest::SHA256.hexdigest(token),
      activity_token_expires_at: deadline + RELEASE_GRACE
    )
    {
      run_id: run_id,
      path: "/api/v1/runtime_runs/#{run_id}/events",
      token: token,
      deadline: deadline.iso8601,
      share_narration: narration_shared && agent.share_working_narration?
    }
  end

  def valid_activity_token?(token)
    token.is_a?(String) && token.bytesize <= 256 && activity_token_digest.present? &&
      activity_token_expires_at&.future? && chat&.respondable? &&
      chat.agents.exists?(agent_id) && agent.reload.eligible_for_conversation? &&
      ActiveSupport::SecurityUtils.secure_compare(activity_token_digest, Digest::SHA256.hexdigest(token))
  end

  def reconcile_activity!
    return if resident_turn.present? && !resident_turn.finished_at?
    return unless live_activity? && !execution_state.in?(TERMINAL_STATES) && execution_deadline_at&.past?

    with_lock do
      return unless live_activity? && !execution_state.in?(TERMINAL_STATES)

      latest_report = agent_runtime_attempts.maximum(:last_report_at)
      if dispatch_claimed_at.nil? && execution_deadline_at&.past?
        update!(execution_state: "cancelled", finished_at: Time.current)
      elsif execution_deadline_at&.past? && (latest_report || execution_deadline_at) < RELEASE_GRACE.ago
        update!(execution_state: "outcome_unknown", finished_at: Time.current)
      end
    end
  end

  def finish_execution!(state)
    return unless state.in?(TERMINAL_STATES)
    return if execution_state.in?(TERMINAL_STATES - [ "outcome_unknown" ])

    update!(execution_state: state, finished_at: Time.current, duration_ms: elapsed_ms)
  end

  def live_activity_json
    attempts = agent_runtime_attempts.order(:number).to_a
    latest = attempts.last
    stored_snapshot = latest&.snapshot || {}
    snapshot = stored_snapshot.slice("operations", "commentary", "plan", "narration_capability", "fallback")
    replies = linked_messages.count
    state = execution_state
    ongoing = !state.in?(TERMINAL_STATES)
    health = if latest&.last_report_at
      latest.last_report_at < 30.seconds.ago && ongoing ? "stale" : "live"
    else
      "connecting"
    end
    helpers_shared = narration_shared && agent.reload.share_working_narration?
    helpers = RuntimeSubagents.new(helpers_shared ? stored_snapshot[RuntimeSubagents::KEY] : nil)
    helpers.gap! if !ongoing || health != "live" || stored_snapshot["fallback"]
    snapshot.merge!(helpers.public_snapshot)
    {
      run_id: run_id, revision: attempts.sum(&:revision) + (ongoing ? 0 : 1_000_000),
      status: state, active: ongoing,
      status_label: {
        "queued" => "is queued", "preparing" => "is preparing",
        "running" => "is working", "completed" => "finished",
        "failed" => "finished with an error", "timed_out" => "timed out",
        "cancelled" => "was cancelled", "busy" => "is already busy",
        "outcome_unknown" => "lost contact; outcome unconfirmed"
      }[state],
      reporter_health: health, snapshot: snapshot,
      narration_shared: helpers_shared,
      last_report_at: latest&.last_report_at&.iso8601,
      reply_count: replies, reply_label: replies.positive? ? "#{replies} #{'reply'.pluralize(replies)} posted" : "No linked reply",
      detail_dropped: attempts.sum(&:dropped_count),
      history_truncated: [ attempts.sum(&:detail_count) - 100, 0 ].max,
      events: attempts.flat_map { |attempt|
        attempt.agent_runtime_events.order(:seq).last(100).filter_map { |event|
          data = event.data.except(RuntimeSubagents::KEY, "subagents", "subagents_overflow", "subagents_overflow_capped")
          if event.event_type == "agent.status_changed"
            next unless helpers_shared
            data = RuntimeSubagents.public_child(event.data)
            next unless data
          end
          { id: "#{attempt.attempt_id}:#{event.seq}", type: event.event_type, data: data }
        }
      }.last(100)
    }
  end

  private

  private :prepare_activity_configuration!, :claim_dispatch_unchecked!, :claim_released_wake!

  def enqueue_live_dispatch
    ManualAgentResponseJob.perform_later(chat, agent, runtime_interaction_id: id)
  end

end
