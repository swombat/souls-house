class ResidentTurn < ApplicationRecord

  class SessionBusy < StandardError; end
  ACTIVE_STATES = %w[starting running unknown].freeze
  belongs_to :agent
  belongs_to :agent_runtime_interaction
  encrypts :payload
  scope :occupying_capacity, -> { where(state: ACTIVE_STATES) }
  scope :pending, -> { where(finished_at: nil) }

  def self.enabled?
    ENV["SOULSHOUSE_ASYNC_TURNS"] == "1"
  end

  def self.capacity
    Setting.instance.resident_turn_limit
  end

  def self.enqueue!(interaction, body, completion_context: {})
    transaction do
      connection.execute("SELECT pg_advisory_xact_lock(1936680308, 1)")
      raise SessionBusy if pending.where(session_id: body.fetch(:session_id)).exists?
      turn = create!(
        agent: interaction.agent, agent_runtime_interaction: interaction,
        dispatch_id: SecureRandom.uuid, session_id: body.fetch(:session_id),
        payload: body.to_json, completion_context: completion_context
      )
      interaction.update!(execution_state: "queued", execution_deadline_at: nil) if interaction.live_activity?
      ResidentTurnDispatchJob.perform_later
      turn
    end
  end

  # Single installation/host admission gate. No HTTP inside this transaction.
  # Starting and uncertain executions consume slots, even if callbacks say the
  # conversational output is finished. Only the runtime ledger proves exit.
  def self.admit!
    transaction do
      connection.execute("SELECT pg_advisory_xact_lock(1936680308, 1)")
      available = capacity - occupying_capacity.count
      return [] unless available.positive?

      busy_sessions = occupying_capacity.pluck(:session_id)
      last_admitted = where.not(admitted_at: nil).group(:agent_id).maximum(:admitted_at)
      selected = []
      candidates = where(state: "queued").order(:created_at, :id).to_a
      while selected.length < available
        eligible = candidates.reject { |turn| busy_sessions.include?(turn.session_id) }
        break if eligible.empty?
        turn = eligible.min_by { |item| [ last_admitted[item.agent_id] || Time.at(0), item.created_at, item.id ] }
        candidates.delete(turn)
        turn.lock!
        next unless turn.state == "queued" && !turn.finished_at?
        unless turn.eligible?
          turn.cancel!
          next
        end
        turn.update!(state: "starting", admitted_at: Time.current)
        selected << turn.id
        busy_sessions << turn.session_id
        last_admitted[turn.agent_id] = Time.current
      end
      selected
    end
  end

  def cancel!
    with_lock do
      return if finished_at?
      update!(cancel_requested_at: Time.current)
      if state == "queued"
        agent_runtime_interaction.finish_execution!("cancelled")
        update!(state: "cancelled", finished_at: Time.current, payload: "{}")
      end
    end
    if finished_at?
      ResidentTurnCleanupJob.perform_later(agent_id) if Agents::Config.cold_start?
    else
      ResidentTurnPollJob.perform_later(id)
    end
  end

  def eligible?
    return false unless agent.active? && !agent.paused? && agent.external?
    interaction = agent_runtime_interaction
    if interaction.chat
      return false unless interaction.chat.respondable? && interaction.chat.agents.exists?(agent_id)
    end
    # A turn a human message or native invoke caused (#94 B) may only enter
    # the runtime while its dispatch still stands: not discarded, author still
    # a member, inside the six-hour no-new-starts boundary. The claim already
    # checked this, but a turn can wait here in the queue for a long time
    # after its claim, so admission is the last check before execution.
    # Settles the dispatch when it no longer stands. Lock order: this turn,
    # then the dispatch; nothing takes a dispatch and then a turn.
    dispatch = interaction.message_dispatch
    return false if dispatch && !dispatch.with_lock { dispatch.deliverable! }
    subscription_id = completion_context["telegram_subscription_id"]
    return false if subscription_id && !TelegramSubscription.active.where(id: subscription_id, agent: agent).exists?
    true
  end

  def prepare!
    with_lock do
      return if prepared_at?
      interaction = agent_runtime_interaction
      body = JSON.parse(payload)
      if interaction.live_activity?
        interaction.update!(execution_state: "preparing", execution_deadline_at: 10.minutes.from_now)
        body["activity"] = interaction.activity_configuration!
      end
      update!(payload: body.to_json, prepared_at: Time.current)
    end
  end

  def record_check!(state: nil, diagnostic: nil)
    with_lock do
      return if finished_at?
      fields = {
        checked_at: Time.current,
        completion_context: completion_context.merge("dispatch_diagnostic" => diagnostic)
      }
      fields[:state] = state if state
      update!(fields)
    end
  end

  # Console-only recovery until the operator has proved the previous process
  # group/container stopped. Never call from timeout or heartbeat automation.
  def resolve_after_containment!(operator:, reason:)
    raise ArgumentError, "site administrator and containment reason required" unless operator&.is_site_admin? && reason.to_s.strip.length >= 10
    raise ArgumentError, "only uncertain turns can be resolved" unless state == "unknown"
    client = ChaosTriggerClient.new(agent_runtime_interaction.endpoint_url, agent.trigger_bearer_token)
    response = client.turn_status(dispatch_id)
    remote = response[:body]
    if response[:status] == 200 && remote["state"] == "unknown"
      response = client.resolve_turn(dispatch_id)
      raise "Runtime did not acknowledge containment" unless response.dig(:body, "state") == "cancelled"
    elsif !(response[:status] == 404 && remote["ledger_id"].present? && remote["ledger_id"] != ledger_id)
      raise "Runtime still executing or unreachable; reservation retained"
    end
    update!(completion_context: completion_context.merge("containment_operator_id" => operator.id, "containment_reason" => reason))
    finish!({ "status" => 409, "body" => { "status" => "cancelled" } }, cancelled: true)
  end

  def finish!(result, cancelled: false)
    with_lock do
      return if finished_at?
      interaction = agent_runtime_interaction
      body = result["body"].is_a?(Hash) ? result["body"].deep_dup : {}
      unless body["status"].in?(%w[ok error timeout already_running])
        body["status"] = "error"
        body["returncode"] = 1
      end
      fields = { status: result.fetch("status"), body: body }
      fields[:execution_outcome] = "cancelled" if cancelled
      interaction.with_lock do
        # Containment resolves occupancy, not the accounting already received
        # before a shim crash. A synthetic cancellation has no replacement usage.
        unless cancelled && interaction.finished_at? && result.dig("body", "status") == "cancelled"
          interaction.update!(error_class: nil, error_message: nil)
          interaction.record_result!(fields)
        end
      end
      ResidentTurnCompletion.new(self, result.merge("body" => body)).call
      update!(state: cancelled ? "cancelled" : "finished", finished_at: Time.current, payload: "{}")
    end
    ResidentTurnDispatchJob.perform_later
    ResidentTurnCleanupJob.perform_later(agent_id) if Agents::Config.cold_start?
  end

end
