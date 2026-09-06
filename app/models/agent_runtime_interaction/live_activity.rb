module AgentRuntimeInteraction::LiveActivity

  extend ActiveSupport::Concern

  TERMINAL_STATES = %w[completed failed timed_out cancelled busy outcome_unknown].freeze
  PREPARATION_WINDOW = 10.minutes
  RELEASE_GRACE = 10.minutes

  included do
    has_many :agent_runtime_attempts, dependent: :destroy
    has_many :linked_messages, class_name: "Message", foreign_key: :runtime_interaction_id, dependent: :nullify
    attr_accessor :enqueue_dispatch
    after_create_commit :enqueue_live_dispatch, if: :enqueue_dispatch
  end

  class_methods do
    def live_activity_enabled?
      ENV.fetch("SOULSHOUSE_LIVE_ACTIVITY", "1") != "0"
    end

    def reserve!(agent:, chat:, enqueue: false)
      chat.with_lock do
        raise ArgumentError, "Conversation unavailable" unless chat.respondable? && chat.manual_responses? && chat.agents.exists?(agent.id)
        agent.reload.require_conversation_runtime!
        chat.agent_runtime_interactions.where(agent: agent, finished_at: nil).each(&:reconcile_activity!)
        raise ArgumentError, "#{agent.name} is already responding" if chat.agent_response_active?(agent)

        create!(
          agent: agent, chat: chat, trigger_kind: "conversation",
          conversation_obfuscated_id: chat.to_param, requested_by: "souls.house",
          session_id: "#{agent.uuid}-#{chat.id}", started_at: Time.current,
          run_id: SecureRandom.uuid, execution_state: "queued",
          execution_deadline_at: PREPARATION_WINDOW.from_now,
          narration_shared: agent.share_working_narration?,
          enqueue_dispatch: enqueue
        )
      end
    end
  end

  def live_activity?
    run_id.present?
  end

  def claim_dispatch!
    with_lock do
      reconcile_activity!
      return false unless execution_state == "queued" && dispatch_claimed_at.nil?

      update!(dispatch_claimed_at: Time.current, execution_state: "preparing")
      true
    end
  end

  def activity_configuration!
    token = SecureRandom.hex(32)
    # A persistent trigger can make one resumed and one fresh invocation.
    deadline = (2 * ChaosTriggerClient::DEFAULT_RUNTIME_TIMEOUT_SECS + 60).seconds.from_now
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
    snapshot = latest&.snapshot || {}
    replies = linked_messages.count
    state = execution_state
    ongoing = !state.in?(TERMINAL_STATES)
    health = if latest&.last_report_at
      latest.last_report_at < 30.seconds.ago && ongoing ? "stale" : "live"
    else
      "connecting"
    end
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
      narration_shared: narration_shared && agent.share_working_narration?,
      last_report_at: latest&.last_report_at&.iso8601,
      reply_count: replies, reply_label: replies.positive? ? "#{replies} #{'reply'.pluralize(replies)} posted" : "No linked reply",
      detail_dropped: attempts.sum(&:dropped_count),
      history_truncated: [ attempts.sum(&:detail_count) - 100, 0 ].max,
      events: attempts.flat_map { |attempt|
        attempt.agent_runtime_events.order(:seq).last(100).map { |event|
          { id: "#{attempt.attempt_id}:#{event.seq}", type: event.event_type, data: event.data }
        }
      }.last(100)
    }
  end

  private

  def enqueue_live_dispatch
    ManualAgentResponseJob.perform_later(chat, agent, runtime_interaction_id: id)
  end

end
