class AgentRuntimeUsageReport

  DETAILED_TOKEN_FIELDS = %i[
    uncached_input_tokens
    cache_creation_input_tokens
    cache_read_input_tokens
    output_tokens
    reasoning_output_tokens
  ].freeze
  TOKEN_FIELDS = ([ :input_tokens ] + DETAILED_TOKEN_FIELDS).freeze
  FILTER_FIELDS = %i[
    trigger_kind
    provider
    model
    session_outcome
    session_roll_reason
  ].freeze

  attr_reader :agent, :from, :to, :filters

  def initialize(agent:, from:, to:, filters: {})
    @agent = agent
    @from = from.utc
    @to = to.utc
    @filters = filters.to_h.symbolize_keys.slice(*FILTER_FIELDS).compact_blank

    raise ArgumentError, "UTC report window must end at or after it starts" if @to < @from
  end

  def call
    stored_interactions = scope.to_a
    interactions = stored_interactions.reject(&:session_busy?)

    {
      window: {
        from: from.iso8601,
        to: to.iso8601,
        timezone: "UTC"
      },
      filters: filters,
      filter_options: filter_options,
      summary: summary_for(interactions).merge(
        busy_retries: stored_interactions.count(&:session_busy?)
      ),
      groups: groups_for(interactions),
      sessions: interactions
        .group_by { |interaction| logical_session_id(interaction) }
        .map { |session_id, rows| session_json(session_id, rows) }
        .sort_by { |session| session[:last_observed_at].to_s }
        .reverse
    }
  end

  private

  def scope
    relation = agent.agent_runtime_interactions
      .includes(:chat)
      .where(started_at: from..to)
      .order(:started_at, :id)

    filters.each do |field, value|
      relation = relation.where(field => value)
    end

    relation
  end

  def filter_options
    relation = agent.agent_runtime_interactions.where(started_at: from..to)

    FILTER_FIELDS.to_h do |field|
      [ field, relation.where.not(field => [ nil, "" ]).distinct.order(field).pluck(field) ]
    end
  end

  def summary_for(interactions)
    {
      interactions: interactions.size,
      logical_sessions: interactions.map { |row| logical_session_id(row) }.uniq.size,
      chaos_processes: interactions.filter_map(&:chaos_session_id).uniq.size,
      provider_requests: sum_local_usage(interactions, :provider_request_count),
      provider_request_unknown_rows: local_usage_unknown_count(interactions, :provider_request_count),
      fresh: interactions.count { |row| row.session_outcome == "fresh" },
      resumed: interactions.count { |row| row.session_outcome == "resumed" },
      rolled: interactions.count { |row| row.session_outcome == "rolled" },
      fallbacks: interactions.count { |row| row.session_outcome == "fresh_fallback" || row.fresh_fallback? },
      complete_usage_rows: interactions.count { |row| telemetry_state(row) == "complete" },
      incomplete_usage_rows: interactions.count { |row| telemetry_state(row) == "incomplete" },
      unavailable_usage_rows: interactions.count { |row| telemetry_state(row) == "unavailable" },
      unsupported_usage_rows: interactions.count { |row| telemetry_state(row) == "unsupported" },
      selected_prompt_bytes: sum_known(interactions, :selected_prompt_bytes),
      selected_prompt_unknown_rows: unknown_count(interactions, :selected_prompt_bytes),
      tokens: token_totals(interactions),
      token_unknown_rows: token_unknown_counts(interactions),
      estimated_cost_usd: estimated_cost_total(interactions),
      estimated_cost_unknown_rows: estimated_cost_unknown_count(interactions)
    }
  end

  def groups_for(interactions)
    {
      trigger_kinds: grouped_counts(interactions, :trigger_kind),
      providers: grouped_counts(interactions, :provider),
      models: grouped_counts(interactions, :model),
      session_outcomes: grouped_counts(interactions, :session_outcome),
      roll_reasons: grouped_counts(interactions, :session_roll_reason),
      chaos_processes: grouped_counts(interactions, :chaos_session_id),
      hours_utc: interactions
        .group_by { |row| row.started_at&.utc&.beginning_of_hour&.iso8601 || "unknown" }
        .transform_values(&:size)
    }
  end

  def session_json(session_id, interactions)
    chaos_ids = interactions.filter_map(&:chaos_session_id).uniq
    first_started_at = interactions.filter_map(&:started_at).min
    last_observed_at = interactions.filter_map { |row| row.finished_at || row.started_at }.max
    telemetry_states = interactions.map { |row| telemetry_state(row) }.tally

    {
      session_id: session_id,
      trigger_kinds: interactions.filter_map(&:trigger_kind).uniq,
      conversation_id: interactions.filter_map(&:conversation_obfuscated_id).first,
      chat_id: interactions.filter_map { |row| row.chat&.to_param }.first,
      account_id: agent.account.to_param,
      first_observed_at: first_started_at&.utc&.iso8601,
      last_observed_at: last_observed_at&.utc&.iso8601,
      active_duration_ms: duration_between(first_started_at, last_observed_at),
      interaction_count: interactions.size,
      chaos_process_ids: chaos_ids,
      chaos_process_count: chaos_ids.size,
      outcomes: grouped_counts(interactions, :session_outcome),
      latest_outcome: interactions.last&.session_outcome,
      roll_reasons: interactions.filter_map(&:session_roll_reason).tally,
      providers: interactions.filter_map(&:provider).uniq,
      models: interactions.filter_map(&:model).uniq,
      cache_ttls: interactions.filter_map(&:cache_ttl).uniq,
      chaos_versions: interactions.filter_map(&:chaos_version).uniq,
      provider_request_count: sum_local_usage(interactions, :provider_request_count),
      provider_request_unknown_rows: local_usage_unknown_count(interactions, :provider_request_count),
      selected_prompt_bytes: sum_known(interactions, :selected_prompt_bytes),
      selected_prompt_unknown_rows: unknown_count(interactions, :selected_prompt_bytes),
      tokens: token_totals(interactions),
      token_unknown_rows: token_unknown_counts(interactions),
      estimated_cost_usd: estimated_cost_total(interactions),
      estimated_cost_unknown_rows: estimated_cost_unknown_count(interactions),
      telemetry_states: telemetry_states,
      telemetry_state: aggregate_telemetry_state(telemetry_states),
      interactions: interactions.map { |row| interaction_json(row) }
    }
  end

  def interaction_json(interaction)
    state = telemetry_state(interaction)

    {
      id: interaction.to_param,
      trigger_kind: interaction.trigger_kind,
      started_at: interaction.started_at&.utc&.iso8601,
      finished_at: interaction.finished_at&.utc&.iso8601,
      duration_ms: interaction.duration_ms,
      transport_status: interaction.transport_status,
      runtime_status: interaction.runtime_status,
      runtime_returncode: interaction.runtime_returncode,
      persistent_session_requested: interaction.persistent_session_requested,
      session_mapping_found: interaction.session_mapping_found,
      resume_attempted: interaction.resume_attempted,
      session_outcome: interaction.session_outcome,
      session_roll_reason: interaction.session_roll_reason,
      changed_identity_files: interaction.changed_identity_files,
      prior_chaos_session_id: interaction.prior_chaos_session_id,
      chaos_session_id: interaction.chaos_session_id,
      session_trigger_sequence: interaction.session_trigger_sequence,
      session_age_seconds: interaction.session_age_seconds,
      prompt_mode: interaction.prompt_mode,
      full_prompt_bytes: interaction.full_prompt_bytes,
      delta_prompt_bytes: interaction.delta_prompt_bytes,
      selected_prompt_bytes: interaction.selected_prompt_bytes,
      prompt_component_bytes: interaction.prompt_component_bytes,
      chaos_version: interaction.chaos_version,
      provider: interaction.provider,
      model: interaction.model,
      cache_ttl: interaction.cache_ttl,
      chaos_telemetry_status: interaction.chaos_telemetry_status,
      unsupported_chaos_telemetry_schema_version: interaction.unsupported_chaos_telemetry_schema_version,
      provider_request_count: local_usage_value(interaction, :provider_request_count),
      usage_scope: interaction.usage_scope,
      usage_complete: interaction.usage_complete,
      telemetry_schema_version: interaction.telemetry_schema_version,
      telemetry_state: state,
      telemetry_state_reason: telemetry_state_reason(interaction, state),
      tokens: TOKEN_FIELDS.to_h { |field| [ field, local_usage_value(interaction, field) ] },
      estimated_cost: interaction.estimated_cost
    }
  end

  def logical_session_id(interaction)
    interaction.session_id.presence || "interaction-#{interaction.id}"
  end

  def duration_between(started_at, finished_at)
    return if started_at.blank? || finished_at.blank?

    ((finished_at - started_at) * 1000).round
  end

  def token_totals(interactions)
    TOKEN_FIELDS.to_h { |field| [ field, sum_local_usage(interactions, field) ] }
  end

  def token_unknown_counts(interactions)
    TOKEN_FIELDS.to_h { |field| [ field, local_usage_unknown_count(interactions, field) ] }
  end

  def estimated_cost_total(interactions)
    amounts = interactions.filter_map do |interaction|
      cost = interaction.estimated_cost
      BigDecimal(cost[:amount_usd]) if cost[:amount_usd]
    end
    amounts.sum.to_s("F") if amounts.any?
  end

  def estimated_cost_unknown_count(interactions)
    interactions.count { |interaction| interaction.estimated_cost[:amount_usd].nil? }
  end

  def grouped_counts(interactions, field)
    interactions
      .group_by { |row| row.public_send(field).presence || "unknown" }
      .transform_values(&:size)
  end

  def sum_known(interactions, field)
    values = interactions.filter_map { |interaction| interaction.public_send(field) }
    values.sum if values.any?
  end

  def unknown_count(interactions, field)
    interactions.count { |interaction| interaction.public_send(field).nil? }
  end

  def sum_local_usage(interactions, field)
    values = interactions.filter_map do |interaction|
      local_usage_value(interaction, field)
    end
    values.sum if values.any?
  end

  def local_usage_unknown_count(interactions, field)
    interactions.count do |interaction|
      !local_usage?(interaction) || interaction.public_send(field).nil?
    end
  end

  # Telemetry trust decisions live on AgentRuntimeInteraction; this report
  # only aggregates them. Keep it that way — a second copy of the state
  # machine here is how the two views of "trustworthy usage" drift apart.
  def local_usage?(interaction)
    interaction.local_usage?
  end

  def local_usage_value(interaction, field)
    interaction.public_send(field) if local_usage?(interaction)
  end

  def telemetry_state(interaction)
    interaction.telemetry_state
  end

  def telemetry_state_reason(interaction, state)
    case state
    when "unavailable"
      if interaction.chaos_telemetry_status == "legacy"
        "Chaos runtime reported only legacy cumulative usage"
      else
        "runtime image did not report versioned invocation telemetry"
      end
    when "unsupported"
      if interaction.unsupported_chaos_telemetry_schema_version.present?
        "Chaos runtime reported unsupported telemetry schema version #{interaction.unsupported_chaos_telemetry_schema_version}"
      else
        "runtime reported unsupported telemetry schema version #{interaction.telemetry_schema_version}"
      end
    when "complete"
      if interaction.usage_scope == "trigger"
        "versioned trigger-local telemetry complete across multiple Chaos invocations"
      else
        "versioned invocation-local telemetry complete"
      end
    when "incomplete"
      if interaction.usage_scope.present? && !interaction.usage_scope.in?(AgentRuntimeInteraction::LOCAL_USAGE_SCOPES)
        "usage scope is #{interaction.usage_scope}, not invocation or trigger"
      elsif interaction.usage_complete == false
        "runtime marked invocation telemetry incomplete"
      else
        "runtime did not confirm complete invocation telemetry"
      end
    end
  end

  def aggregate_telemetry_state(states)
    return "unsupported" if states["unsupported"].to_i.positive?
    return "unavailable" if states["unavailable"].to_i.positive?
    return "incomplete" if states["incomplete"].to_i.positive?

    "complete"
  end

end
