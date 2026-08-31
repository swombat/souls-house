class AgentRuntimeInteraction < ApplicationRecord

  SUPPORTED_TELEMETRY_SCHEMA_VERSION = 1
  LOCAL_USAGE_SCOPES = %w[invocation trigger].freeze
  RUNTIME_OUTPUT_CAPTURE_LIMIT = 4_000
  ACTIVE_WINDOW = 12.minutes

  belongs_to :agent
  belongs_to :chat, optional: true
  after_commit :broadcast_agent_runtime_interactions_refresh, on: [ :create, :update, :destroy ]

  validates :trigger_kind, presence: true
  validates :started_at, presence: true
  validates :provider_auth_mode, inclusion: { in: Agent::PROVIDER_AUTH_MODES }

  scope :recent, -> { order(created_at: :desc) }
  scope :timeline_order, -> { order(Arel.sql("COALESCE(finished_at, started_at, created_at) ASC"), :id) }
  scope :active, -> { where(finished_at: nil).where("started_at >= ?", ACTIVE_WINDOW.ago) }

  def self.record_trigger!(agent:, chat:, trigger_kind:, conversation_id:, requested_by:, session_id:, endpoint_url:, request_text:, last_included_message_id: nil, provider_auth_mode: "api_key")
    interaction = create!(
      agent: agent,
      chat: chat,
      trigger_kind: trigger_kind,
      conversation_obfuscated_id: conversation_id,
      requested_by: requested_by,
      session_id: session_id,
      endpoint_url: endpoint_url,
      request_text: request_text,
      last_included_message_id: last_included_message_id,
      provider_auth_mode: provider_auth_mode,
      started_at: Time.current
    )

    result = yield
    interaction.record_result!(result)
    result
  rescue StandardError => e
    interaction&.record_error!(e)
    raise
  end

  def record_result!(result)
    body = (result[:body] || {}).deep_dup
    full_invocation_text = body.delete("full_invocation_text")
    telemetry = body["telemetry"].presence || {}
    runtime = telemetry["runtime"].presence || {}
    session = telemetry["session"].presence || {}
    prompt = telemetry["prompt"].presence || {}
    telemetry_usage = telemetry["usage"]
    versioned_usage = telemetry_usage.is_a?(Hash)
    usage = versioned_usage ? telemetry_usage : body["usage"].presence || {}
    # Only the versioned telemetry envelope promises invocation-local usage.
    # Unversioned fields may still be process-cumulative output from an older
    # Chaos runtime, so keep them in the compatibility columns rather than
    # presenting them as trustworthy detailed accounting.
    detailed_usage = versioned_usage
    cache_read_tokens = cache_read_tokens_from(usage) if detailed_usage
    compatible_cached_tokens = detailed_usage ? cache_read_tokens : usage["cached_input_tokens"]
    cache_creation_tokens = usage["cache_creation_input_tokens"] if detailed_usage
    uncached_tokens = uncached_input_tokens_from(
      usage,
      cache_creation_tokens: cache_creation_tokens,
      cache_read_tokens: cache_read_tokens
    ) if detailed_usage
    reasoning_output_tokens = usage["reasoning_output_tokens"] if detailed_usage
    provider_request_count = usage["provider_request_count"] if detailed_usage

    update!(
      transport_status: result[:status],
      runtime_status: body["status"],
      runtime_returncode: body["returncode"],
      stdout: body["stdout"],
      stderr: body["stderr"],
      full_invocation_text: full_invocation_text,
      chaos_session_id: session["chaos_process_id"] || body["chaos_session_id"],
      session_resumed: body.key?("session_resumed") ? body["session_resumed"] : derived_session_flag(session, "resumed"),
      fresh_fallback: body.key?("fresh_fallback") ? body["fresh_fallback"] : derived_session_flag(session, "fresh_fallback"),
      telemetry_schema_version: telemetry["schema_version"],
      chaos_telemetry_status: telemetry["chaos_telemetry_status"],
      unsupported_chaos_telemetry_schema_version: telemetry["unsupported_chaos_telemetry_schema_version"],
      chaos_version: runtime["chaos_version"],
      provider: runtime["provider"],
      model: runtime["model"],
      cache_ttl: runtime["cache_ttl"],
      persistent_session_requested: session["persistent_requested"],
      session_mapping_found: session["mapping_found"],
      resume_attempted: session["resume_attempted"],
      session_outcome: session["outcome"],
      session_roll_reason: session["roll_reason"] || body["session_roll_reason"],
      changed_identity_files: session.key?("changed_identity_files") ? session["changed_identity_files"] : changed_identity_files,
      prior_chaos_session_id: session["prior_chaos_process_id"],
      session_trigger_sequence: session["trigger_sequence"],
      session_age_seconds: session["session_age_seconds"],
      prompt_mode: prompt["mode"],
      full_prompt_bytes: prompt["full_prompt_bytes"],
      delta_prompt_bytes: prompt["delta_prompt_bytes"],
      selected_prompt_bytes: prompt["selected_prompt_bytes"],
      prompt_component_bytes: prompt.key?("components") ? prompt["components"] : prompt_component_bytes,
      usage_scope: usage["scope"],
      input_tokens: usage["input_tokens"],
      uncached_input_tokens: uncached_tokens,
      cache_creation_input_tokens: cache_creation_tokens,
      cache_read_input_tokens: cache_read_tokens,
      cached_input_tokens: compatible_cached_tokens,
      output_tokens: usage["output_tokens"],
      reasoning_output_tokens: reasoning_output_tokens,
      provider_request_count: provider_request_count,
      usage_complete: usage_complete_value(versioned_usage, usage),
      response_body: body,
      finished_at: Time.current,
      duration_ms: elapsed_ms
    )
  end

  def record_error!(error)
    update!(
      error_class: error.class.name,
      error_message: error.message,
      finished_at: Time.current,
      duration_ms: elapsed_ms
    )
  end

  def cache_read_ratio
    token_ratio(cache_read_input_tokens)
  end

  def cache_creation_ratio
    token_ratio(cache_creation_input_tokens)
  end

  def fresh_session?
    session_outcome.in?(%w[legacy_fresh fresh])
  end

  def resumed_session?
    session_outcome == "resumed"
  end

  def cold_start?
    prompt_mode == "full" || fresh_session? || session_outcome.in?(%w[rolled fresh_fallback])
  end

  def provider_requests_per_trigger
    provider_request_count
  end

  def local_usage?
    telemetry_schema_version == SUPPORTED_TELEMETRY_SCHEMA_VERSION &&
      usage_scope.in?(LOCAL_USAGE_SCOPES)
  end

  def telemetry_state
    return "unavailable" if telemetry_schema_version.nil?
    return "unsupported" if telemetry_schema_version > SUPPORTED_TELEMETRY_SCHEMA_VERSION ||
      chaos_telemetry_status == "unsupported" ||
      unsupported_chaos_telemetry_schema_version.present?
    return "unavailable" if chaos_telemetry_status.in?(%w[missing legacy])
    return "complete" if usage_complete == true && local_usage?

    "incomplete"
  end

  def token_breakdown
    {
      input: input_tokens,
      uncached_input: uncached_input_tokens,
      cache_creation_input: cache_creation_input_tokens,
      cache_read_input: cache_read_input_tokens,
      output: output_tokens,
      reasoning_output: reasoning_output_tokens
    }
  end

  def estimated_cost
    AgentRuntimeInteractionCost.new(self).call.merge(
      provider_auth_mode: provider_auth_mode,
      applies_to_billing: !subscription_based?
    )
  end

  def subscription_based?
    provider_auth_mode == "oauth_account"
  end

  def as_debug_json
    {
      id: id,
      trigger_kind: trigger_kind,
      session_id: session_id,
      conversation_id: conversation_obfuscated_id,
      requested_by: requested_by,
      endpoint_url: endpoint_url,
      transport_status: transport_status,
      runtime_status: runtime_status,
      runtime_returncode: runtime_returncode,
      stdout: stdout,
      stderr: stderr,
      error_class: error_class,
      error_message: error_message,
      chaos_session_id: chaos_session_id,
      session_resumed: session_resumed,
      fresh_fallback: fresh_fallback,
      telemetry_schema_version: telemetry_schema_version,
      chaos_telemetry_status: chaos_telemetry_status,
      unsupported_chaos_telemetry_schema_version: unsupported_chaos_telemetry_schema_version,
      chaos_version: chaos_version,
      provider: provider,
      model: model,
      provider_auth_mode: provider_auth_mode,
      subscription_based: subscription_based?,
      cache_ttl: cache_ttl,
      persistent_session_requested: persistent_session_requested,
      session_mapping_found: session_mapping_found,
      resume_attempted: resume_attempted,
      session_outcome: session_outcome,
      session_roll_reason: session_roll_reason,
      changed_identity_files: changed_identity_files,
      prior_chaos_session_id: prior_chaos_session_id,
      session_trigger_sequence: session_trigger_sequence,
      session_age_seconds: session_age_seconds,
      prompt_mode: prompt_mode,
      full_prompt_bytes: full_prompt_bytes,
      delta_prompt_bytes: delta_prompt_bytes,
      selected_prompt_bytes: selected_prompt_bytes,
      prompt_component_bytes: prompt_component_bytes,
      usage_scope: usage_scope,
      input_tokens: input_tokens,
      uncached_input_tokens: uncached_input_tokens,
      cache_creation_input_tokens: cache_creation_input_tokens,
      cache_read_input_tokens: cache_read_input_tokens,
      cached_input_tokens: cached_input_tokens,
      output_tokens: output_tokens,
      reasoning_output_tokens: reasoning_output_tokens,
      provider_request_count: provider_request_count,
      usage_complete: usage_complete,
      estimated_cost: estimated_cost,
      started_at: started_at&.iso8601,
      finished_at: finished_at&.iso8601,
      duration_ms: duration_ms,
      created_at: created_at&.iso8601
    }
  end

  def as_chat_activity_json
    {
      id: to_param,
      agent_id: agent.to_param,
      agent_name: agent.name,
      agent_icon: agent.icon,
      agent_colour: agent.colour,
      trigger_kind: trigger_kind,
      status: chat_activity_status,
      status_label: chat_activity_status_label,
      active: active?,
      conversation_id: conversation_obfuscated_id,
      transport_status: transport_status,
      runtime_status: runtime_status,
      runtime_returncode: runtime_returncode,
      stdout: stdout,
      stderr: stderr,
      error_class: error_class,
      error_message: error_message,
      started_at: started_at&.iso8601,
      finished_at: finished_at&.iso8601,
      duration_ms: duration_ms,
      created_at: (finished_at || started_at || created_at)&.iso8601
    }
  end

  def as_cost_json
    {
      id: to_param,
      chat_id: chat&.to_param,
      chat_title: chat&.title_or_default,
      trigger_kind: trigger_kind,
      summary: interaction_summary,
      requested_by: requested_by,
      provider: provider,
      model: model,
      provider_auth_mode: provider_auth_mode,
      subscription_based: subscription_based?,
      session_outcome: session_outcome,
      prompt_mode: prompt_mode,
      provider_request_count: local_usage? ? provider_request_count : nil,
      telemetry_state: telemetry_state,
      usage_complete: usage_complete,
      tokens: {
        uncached_input_tokens: local_usage? ? uncached_input_tokens : nil,
        cache_creation_input_tokens: local_usage? ? cache_creation_input_tokens : nil,
        cache_read_input_tokens: local_usage? ? cache_read_input_tokens : nil,
        output_tokens: local_usage? ? output_tokens : nil,
        reasoning_output_tokens: local_usage? ? reasoning_output_tokens : nil
      },
      estimated_cost: estimated_cost,
      started_at: started_at&.iso8601,
      duration_ms: duration_ms
    }
  end

  def as_session_json
    as_cost_json.merge(
      session_id: session_id,
      conversation_id: conversation_obfuscated_id,
      transport_status: transport_status,
      runtime_status: runtime_status,
      runtime_returncode: runtime_returncode,
      stdout: stdout,
      stderr: stderr,
      stdout_chars: stdout.to_s.length,
      stderr_chars: stderr.to_s.length,
      output_capture_limit_chars: RUNTIME_OUTPUT_CAPTURE_LIMIT,
      stdout_may_be_truncated: stdout.to_s.length >= RUNTIME_OUTPUT_CAPTURE_LIMIT,
      stderr_may_be_truncated: stderr.to_s.length >= RUNTIME_OUTPUT_CAPTURE_LIMIT,
      error_class: error_class,
      error_message: error_message,
      chaos_session_id: chaos_session_id,
      prior_chaos_session_id: prior_chaos_session_id,
      session_roll_reason: session_roll_reason,
      session_trigger_sequence: session_trigger_sequence,
      session_age_seconds: session_age_seconds,
      persistent_session_requested: persistent_session_requested,
      session_mapping_found: session_mapping_found,
      resume_attempted: resume_attempted,
      full_prompt_bytes: full_prompt_bytes,
      delta_prompt_bytes: delta_prompt_bytes,
      selected_prompt_bytes: selected_prompt_bytes,
      prompt_component_bytes: prompt_component_bytes,
      chaos_version: chaos_version,
      cache_ttl: cache_ttl,
      finished_at: finished_at&.iso8601
    )
  end

  def visible_in_chat_timeline?
    !posted_assistant_message?
  end

  def active?
    finished_at.blank? && started_at.present? && started_at >= ACTIVE_WINDOW.ago
  end

  def session_busy?
    transport_status == 409 && runtime_status == "already_running"
  end

  private

  def interaction_summary
    parts = [ trigger_kind.to_s.humanize ]
    parts << session_outcome.to_s.humanize if session_outcome.present?
    parts << "#{prompt_mode} prompt" if prompt_mode.present?
    parts.join(" · ")
  end

  def cache_read_tokens_from(usage)
    return usage["cache_read_input_tokens"] if usage.key?("cache_read_input_tokens")

    usage["cached_input_tokens"]
  end

  def uncached_input_tokens_from(usage, cache_creation_tokens:, cache_read_tokens:)
    return usage["uncached_input_tokens"] unless usage["uncached_input_tokens"].nil?
    return if usage["input_tokens"].nil? || cache_creation_tokens.nil? || cache_read_tokens.nil?

    usage["input_tokens"] - cache_creation_tokens - cache_read_tokens
  end

  def token_ratio(category_tokens)
    return if category_tokens.nil? || input_tokens.nil? || input_tokens.zero?

    category_tokens.to_f / input_tokens
  end

  def usage_complete_value(versioned_usage, usage)
    return usage["complete"] if usage.key?("complete")
    return true if versioned_usage && usage["scope"] == "invocation"

    nil
  end

  def derived_session_flag(session, outcome)
    session["outcome"] == outcome if session.key?("outcome")
  end

  def broadcast_agent_runtime_interactions_refresh
    ActionCable.server.broadcast(
      "Agent:#{agent.obfuscated_id}",
      { action: "refresh", prop: "runtime_interactions" }
    )
    if previous_changes.key?("finished_at")
      ActionCable.server.broadcast(
        "Agent:#{agent.obfuscated_id}",
        { action: "refresh", prop: "cost_report" }
      )
    end

    if chat
      ActionCable.server.broadcast(
        "Chat:#{chat.obfuscated_id}",
        { action: "refresh", prop: "runtime_interactions" }
      )
    end

    broadcast_linked_message_refresh if previous_changes.key?("finished_at")
  end

  def broadcast_linked_message_refresh
    linked_chat = chat || obvious_wake_response_chat
    return unless linked_chat

    ActionCable.server.broadcast(
      "Chat:#{linked_chat.obfuscated_id}",
      { action: "refresh", prop: "messages" }
    )
    ActionCable.server.broadcast(
      "Chat:#{linked_chat.obfuscated_id}",
      { action: "refresh", prop: "cost_breakdown" }
    )
  end

  def obvious_wake_response_chat
    return unless trigger_kind == "wake" && agent && started_at && finished_at

    messages = Message.joins(:chat)
      .where(chats: { account_id: agent.account_id })
      .where(role: "assistant", agent: agent)
      .where(created_at: started_at..(finished_at + 30.seconds))
      .limit(2)
      .to_a

    messages.first.chat if messages.one?
  end

  def elapsed_ms
    return unless started_at

    ((Time.current - started_at) * 1000).round
  end

  def running?
    finished_at.blank?
  end

  def posted_assistant_message?
    return false unless chat && agent && started_at

    upper_bound = finished_at || Time.current
    chat.messages
      .where(role: "assistant", agent: agent)
      .where(created_at: started_at..(upper_bound + 30.seconds))
      .exists?
  end

  def chat_activity_status
    return "running" if running?
    return "failed" if error_message.present? || transport_status.to_i >= 400 || runtime_returncode.to_i.nonzero?

    "completed_without_reply"
  end

  def chat_activity_status_label
    case chat_activity_status
    when "running"
      "is running"
    when "failed"
      "finished with an error"
    else
      "completed without posting a reply"
    end
  end

end
