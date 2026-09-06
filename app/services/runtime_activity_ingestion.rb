class RuntimeActivityIngestion

  class Invalid < StandardError; end

  LABELS = {
    "command" => "Run a command", "files" => "Change files",
    "tool" => "Use an external tool", "search" => "Search the web",
    "delegation" => "Delegate work"
  }.freeze
  TYPES = %w[attempt.started turn.started turn.finished tool.started tool.finished commentary.completed plan.updated heartbeat fallback supervisor.finished warning].freeze
  OUTCOMES = %w[completed failed timed_out outcome_unknown].freeze

  def initialize(run, payload)
    @run, @payload = run, payload
  end

  def call
    raise Invalid unless payload.is_a?(Hash) && payload["schema_version"] == 1 &&
      payload["run_id"] == run.run_id && uuid?(payload["attempt_id"]) &&
      payload["attempt_number"].in?([ 1, 2 ]) && payload["events"].is_a?(Array) &&
      payload["events"].length.between?(1, 50)
    events = payload["events"].map { |event| validate_event(event) }
    raise Invalid unless events.map { |event| event["seq"] }.uniq.length == events.length
    broadcast = false
    run.with_lock do
      attempt = run.agent_runtime_attempts.find_by(attempt_id: payload["attempt_id"])
      unless attempt
        first = events.min_by { |event| event["seq"] }
        raise Invalid unless first["seq"] == 1 && first["type"] == "attempt.started"
        previous = run.agent_runtime_attempts.order(:number).last
        raise Invalid unless payload["attempt_number"] == (previous&.number || 0) + 1
        raise Invalid if previous && !previous.snapshot["fallback"]
        # The synchronous result can arrive before a delayed first callback.
        # Its bounded reporting credential still permits historical detail,
        # but apply never resurrects a terminal run.
        raise Invalid unless run.dispatch_claimed_at?
        attempt = run.agent_runtime_attempts.create!(attempt_id: payload["attempt_id"], number: payload["attempt_number"])
      end
      raise Invalid unless attempt.number == payload["attempt_number"]
      latest = attempt.number == run.agent_runtime_attempts.maximum(:number)
      detail_count = run.agent_runtime_attempts.sum(:detail_count)
      detail_bytes = run.agent_runtime_attempts.sum(:detail_bytes)
      events.sort_by { |event| event["seq"] }.each do |event|
        digest = Digest::SHA256.hexdigest(event.to_json)
        stored = attempt.agent_runtime_events.find_by(seq: event["seq"])
        raise Invalid if stored && stored.payload_digest != digest
        next if stored || event["seq"] <= attempt.last_seq

        data = project(event)
        if event["type"] != "heartbeat"
          bytes = data.to_json.bytesize
          if detail_count < 2_000 && detail_bytes + bytes < 2.megabytes
            attempt.agent_runtime_events.create!(seq: event["seq"], event_type: event["type"], data: data, payload_digest: digest)
            attempt.detail_count += 1
            attempt.detail_bytes += bytes
            detail_count += 1
            detail_bytes += bytes
          else
            attempt.dropped_count += 1
          end
        end
        apply(attempt, event["type"], data, latest: latest)
        if event["type"] == "heartbeat"
          attempt.dropped_count = [ attempt.dropped_count, data.fetch("detail_dropped", 0) ].max
        end
        if latest && event["type"] == "supervisor.finished"
          run.record_result!({ status: nil, execution_outcome: data["outcome"], body: terminal_body(event["data"]) }, from_callback: true)
          attempt.dropped_count = [ attempt.dropped_count, event["data"]["detail_dropped"].to_i.clamp(0, 1_000_000) ].max
        end
        attempt.last_seq = event["seq"]
        attempt.revision += 1
      end
      attempt.last_report_at = Time.current
      if latest && (attempt.last_broadcast_at.nil? || attempt.last_broadcast_at < 1.second.ago || run.finished_at?)
        attempt.last_broadcast_at = Time.current
        broadcast = true
      end
      attempt.save!
    end
    if broadcast && run.chat
      ActionCable.server.broadcast("Chat:#{run.chat.to_param}", {
        action: "runtime_activity_changed", run_id: run.run_id, revision: run.live_activity_json[:revision]
      })
    end
    { accepted: true, share_narration: run.narration_shared && run.agent.reload.share_working_narration? }
  end

  private

  attr_reader :run, :payload

  def uuid?(value)
    value.is_a?(String) && value.match?(/\A[0-9a-f-]{36}\z/)
  end

  def validate_event(event)
    raise Invalid unless event.is_a?(Hash) && event["seq"].is_a?(Integer) &&
      event["seq"].between?(1, 1_000_000) && TYPES.include?(event["type"]) &&
      event["data"].is_a?(Hash)
    event
  end

  def text(value, max = 4_096)
    raise Invalid unless value.is_a?(String) && value.bytesize <= max
    value.gsub(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, "")
  end

  def project(event)
    data = event["data"]
    case event["type"]
    when "attempt.started"
      capability = data["narration_capability"]
      raise Invalid unless capability.in?(%w[supported unsupported unknown])
      { "narration_capability" => capability }
    when "tool.started", "tool.finished"
      category = data["category"]
      raise Invalid unless LABELS.key?(category) && data["outcome"].in?([ nil, "completed", "failed" ])
      { "operation_id" => text(data["operation_id"], 200), "category" => category,
        "label" => LABELS.fetch(category), "outcome" => data["outcome"] }
    when "commentary.completed"
      content = text(data["text"])
      shared_narration? ? { "text" => content } : {}
    when "plan.updated"
      raise Invalid unless data["steps"].is_a?(Array) && data["steps"].size <= 100
      steps = data["steps"].map do |step|
        raise Invalid unless step.is_a?(Hash) && step["status"].in?(%w[pending in_progress completed])
        { "text" => text(step["text"]), "status" => step["status"] }
      end
      shared_narration? ? { "steps" => steps } : {}
    when "supervisor.finished"
      raise Invalid unless data["outcome"].in?(OUTCOMES)
      # Accounting is validated separately and never placed in public event data.
      { "outcome" => data["outcome"] }
    when "heartbeat"
      return {} unless data.key?("operations")
      raise Invalid unless data["operations"].is_a?(Array) && data["operations"].length <= 64
      operations = data["operations"].map do |operation|
        raise Invalid unless operation.is_a?(Hash)
        project({ "type" => "tool.started", "data" => operation })
      end
      { "operations" => operations.index_by { |operation| operation["operation_id"] },
        "detail_dropped" => data["detail_dropped"].to_i.clamp(0, 1_000_000) }
    else
      {}
    end
  end

  def shared_narration?
    run.narration_shared && run.agent.reload.share_working_narration?
  end

  def terminal_body(data)
    telemetry = data["telemetry"]
    result = { "status" => data["runtime_status"].in?(%w[ok error timeout]) ? data["runtime_status"] : nil }
    result["returncode"] = data["returncode"] if data["returncode"].is_a?(Integer)
    return result unless telemetry.is_a?(Hash)

    safe = {}
    safe["schema_version"] = telemetry["schema_version"] if telemetry["schema_version"].is_a?(Integer)
    if telemetry["usage"].is_a?(Hash)
      safe["usage"] = telemetry["usage"].slice(
        "input_tokens", "uncached_input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens",
        "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "provider_request_count"
      ).select { |_, value| value.is_a?(Integer) && value.between?(0, 10**12) }
      safe["usage"]["scope"] = telemetry["usage"]["scope"] if telemetry["usage"]["scope"].in?(%w[invocation trigger])
      safe["usage"]["complete"] = telemetry["usage"]["complete"] == true
    end
    %w[runtime session prompt].each do |section|
      source = telemetry[section]
      next unless source.is_a?(Hash)
      keys = {
        "runtime" => %w[chaos_version provider model cache_ttl],
        "session" => %w[chaos_process_id prior_chaos_process_id outcome persistent_requested mapping_found resume_attempted trigger_sequence session_age_seconds],
        "prompt" => %w[mode full_prompt_bytes delta_prompt_bytes selected_prompt_bytes]
      }.fetch(section)
      safe[section] = source.slice(*keys).select do |_, value|
        value == true || value == false || (value.is_a?(Integer) && value.between?(0, 10**12)) ||
          (value.is_a?(String) && value.bytesize <= 200)
      end
    end
    result["telemetry"] = safe
    result
  end

  def apply(attempt, type, data, latest:)
    snapshot = attempt.snapshot.deep_dup
    case type
    when "attempt.started"
      snapshot.merge!(data)
    when "turn.started"
      run.update!(execution_state: "running") if latest && !run.finished_at?
    when "tool.started"
      operations = snapshot.fetch("operations", {}).except(data["operation_id"])
      operations[data["operation_id"]] = data if operations.size < 256
      snapshot["operations"] = operations
    when "tool.finished"
      snapshot["operations"] = snapshot.fetch("operations", {}).except(data["operation_id"])
    when "heartbeat"
      snapshot["operations"] = data["operations"] if data.key?("operations")
    when "commentary.completed"
      snapshot["commentary"] = data["text"] if data["text"]
    when "plan.updated"
      snapshot["plan"] = data["steps"] if data["steps"]
    when "fallback"
      snapshot["fallback"] = true
      snapshot["operations"] = {}
    when "supervisor.finished"
      snapshot["operations"] = {}
      run.finish_execution!(data["outcome"]) if latest
    end
    attempt.snapshot = snapshot
  end

end
