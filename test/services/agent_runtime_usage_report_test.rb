require "test_helper"

class AgentRuntimeUsageReportTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @from = Time.utc(2026, 7, 18, 12)
    @to = Time.utc(2026, 7, 18, 14)
  end

  test "groups logical sessions while preserving chaos process transitions and invocation totals" do
    create_interaction!(
      started_at: @from + 10.minutes,
      session_id: "conversation-1",
      chaos_session_id: "chaos-a",
      session_outcome: "fresh",
      provider_request_count: 1,
      uncached_input_tokens: 100,
      cache_creation_input_tokens: 900,
      cache_read_input_tokens: 0,
      output_tokens: 50
    )
    create_interaction!(
      started_at: @from + 20.minutes,
      session_id: "conversation-1",
      prior_chaos_session_id: "chaos-a",
      chaos_session_id: "chaos-b",
      session_outcome: "rolled",
      session_roll_reason: "model-changed",
      provider_request_count: 3,
      uncached_input_tokens: 10,
      cache_creation_input_tokens: 20,
      cache_read_input_tokens: 970,
      output_tokens: 25
    )

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call

    assert_equal "UTC", report.dig(:window, :timezone)
    assert_equal 2, report.dig(:summary, :interactions)
    assert_equal 1, report.dig(:summary, :logical_sessions)
    assert_equal 2, report.dig(:summary, :chaos_processes)
    assert_equal 4, report.dig(:summary, :provider_requests)
    assert_equal 920, report.dig(:summary, :tokens, :cache_creation_input_tokens)
    assert_equal 970, report.dig(:summary, :tokens, :cache_read_input_tokens)
    assert_equal "0.00043175", report.dig(:summary, :estimated_cost_usd)
    assert_equal 0, report.dig(:summary, :estimated_cost_unknown_rows)
    assert_equal({ "conversation" => 2 }, report.dig(:groups, :trigger_kinds))
    assert_equal({ "fresh" => 1, "rolled" => 1 }, report.dig(:groups, :session_outcomes))

    session = report.fetch(:sessions).first
    assert_equal "conversation-1", session.fetch(:session_id)
    assert_equal [ "chaos-a", "chaos-b" ], session.fetch(:chaos_process_ids)
    assert_equal 2, session.fetch(:interaction_count)
    assert_equal({ "model-changed" => 1 }, session.fetch(:roll_reasons))
    assert_equal 2, session.fetch(:interactions).size
    assert_equal "complete", session.fetch(:telemetry_state)
  end

  test "does not treat old coarse usage as versioned invocation usage" do
    create_interaction!(
      started_at: @from + 10.minutes,
      session_id: "old-runtime",
      telemetry_schema_version: nil,
      usage_scope: nil,
      usage_complete: nil,
      input_tokens: 100,
      output_tokens: 0
    )

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call

    assert_nil report.dig(:summary, :tokens, :cache_creation_input_tokens)
    assert_nil report.dig(:summary, :tokens, :output_tokens)
    assert_equal 1, report.dig(:summary, :token_unknown_rows, :output_tokens)
    assert_equal 0, report.dig(:summary, :incomplete_usage_rows)
    assert_equal 1, report.dig(:summary, :unavailable_usage_rows)
    assert_equal 0, report.dig(:summary, :complete_usage_rows)

    interaction = report.dig(:sessions, 0, :interactions, 0)
    assert_equal "unavailable", interaction.fetch(:telemetry_state)
    assert_match(/runtime image did not report/, interaction.fetch(:telemetry_state_reason))
  end

  test "keeps reported zero distinct from unknown" do
    create_interaction!(
      started_at: @from + 10.minutes,
      session_id: "reported-zero",
      provider_request_count: 0,
      input_tokens: 0,
      uncached_input_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 0,
      reasoning_output_tokens: nil
    )

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call

    assert_equal 0, report.dig(:summary, :provider_requests)
    assert_equal 0, report.dig(:summary, :tokens, :cache_creation_input_tokens)
    assert_equal 0, report.dig(:summary, :tokens, :output_tokens)
    assert_nil report.dig(:summary, :tokens, :reasoning_output_tokens)
    assert_equal 0, report.dig(:summary, :token_unknown_rows, :output_tokens)
    assert_equal 1, report.dig(:summary, :token_unknown_rows, :reasoning_output_tokens)
  end

  test "includes trigger-local totals from a resume fallback with two Chaos invocations" do
    create_interaction!(
      started_at: @from + 10.minutes,
      session_id: "fallback-trigger",
      usage_scope: "trigger",
      usage_complete: true,
      session_outcome: "fresh_fallback",
      provider_request_count: 4,
      input_tokens: 2_000,
      uncached_input_tokens: 100,
      cache_creation_input_tokens: 300,
      cache_read_input_tokens: 1_600,
      output_tokens: 80
    )

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call

    assert_equal 4, report.dig(:summary, :provider_requests)
    assert_equal 2_000, report.dig(:summary, :tokens, :input_tokens)
    assert_equal 300, report.dig(:summary, :tokens, :cache_creation_input_tokens)
    assert_equal 0, report.dig(:summary, :provider_request_unknown_rows)
    assert_equal 1, report.dig(:summary, :complete_usage_rows)

    interaction = report.dig(:sessions, 0, :interactions, 0)
    assert_equal "complete", interaction.fetch(:telemetry_state)
    assert_match(/trigger-local telemetry complete/, interaction.fetch(:telemetry_state_reason))
    assert_equal 4, interaction.fetch(:provider_request_count)
  end

  test "uses exact UTC range boundaries" do
    create_interaction!(started_at: @from - 1.second, session_id: "before")
    create_interaction!(started_at: @from, session_id: "inside-start")
    create_interaction!(started_at: @to, session_id: "inside-end")
    create_interaction!(started_at: @to + 1.second, session_id: "after")

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call

    assert_equal 2, report.dig(:summary, :interactions)
    assert_equal [ "inside-end", "inside-start" ], report.fetch(:sessions).map { |session| session[:session_id] }
  end

  test "excludes session busy retries from usage and session timelines" do
    create_interaction!(started_at: @from + 10.minutes, session_id: "telegram-session", trigger_kind: "telegram")
    create_interaction!(
      started_at: @from + 11.minutes,
      session_id: "telegram-session",
      trigger_kind: "telegram",
      transport_status: 409,
      runtime_status: "already_running",
      telemetry_schema_version: nil,
      usage_scope: nil,
      usage_complete: nil
    )

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call

    assert_equal 1, report.dig(:summary, :interactions)
    assert_equal 1, report.dig(:summary, :busy_retries)
    assert_equal 1, report.dig(:sessions, 0, :interactions).size
  end

  test "normalizes an explicitly offset window to UTC" do
    report = AgentRuntimeUsageReport.new(
      agent: @agent,
      from: Time.iso8601("2026-07-18T14:00:00+02:00"),
      to: Time.iso8601("2026-07-18T16:00:00+02:00")
    ).call

    assert_equal "2026-07-18T12:00:00Z", report.dig(:window, :from)
    assert_equal "2026-07-18T14:00:00Z", report.dig(:window, :to)
    assert_equal "UTC", report.dig(:window, :timezone)
  end

  test "filters dimensions and keeps filter options for the UTC window" do
    create_interaction!(
      started_at: @from + 10.minutes,
      session_id: "wake-1",
      trigger_kind: "wake",
      provider: "anthropic",
      model: "claude-fable-5",
      session_outcome: "resumed"
    )
    create_interaction!(
      started_at: @from + 20.minutes,
      session_id: "chat-1",
      trigger_kind: "conversation",
      provider: "openai",
      model: "gpt-5.5",
      session_outcome: "fresh"
    )

    report = AgentRuntimeUsageReport.new(
      agent: @agent,
      from: @from,
      to: @to,
      filters: { trigger_kind: "wake", provider: "anthropic" }
    ).call

    assert_equal 1, report.dig(:summary, :interactions)
    assert_equal "wake-1", report.dig(:sessions, 0, :session_id)
    assert_equal({ trigger_kind: "wake", provider: "anthropic" }, report.fetch(:filters))
    assert_equal [ "conversation", "wake" ], report.dig(:filter_options, :trigger_kind)
    assert_equal [ "anthropic", "openai" ], report.dig(:filter_options, :provider)
  end

  test "reports session duration lifecycle decisions prompt sizes and runtime fields" do
    interaction = create_interaction!(
      started_at: @from + 10.minutes,
      finished_at: @from + 11.minutes,
      duration_ms: 60_000,
      session_id: "timeline-1",
      persistent_session_requested: true,
      session_mapping_found: true,
      resume_attempted: true,
      session_outcome: "resumed",
      prior_chaos_session_id: "chaos-a",
      chaos_session_id: "chaos-a",
      session_trigger_sequence: 4,
      session_age_seconds: 300,
      prompt_mode: "delta",
      full_prompt_bytes: 90_000,
      delta_prompt_bytes: 3_000,
      selected_prompt_bytes: 3_000,
      prompt_component_bytes: { "request" => 2_000 },
      chaos_version: "chaos 0.1.0 (abc1234)",
      provider: "anthropic",
      model: "claude-fable-5",
      cache_ttl: "1h",
      provider_request_count: 2,
      uncached_input_tokens: 10,
      cache_creation_input_tokens: 20,
      cache_read_input_tokens: 970,
      output_tokens: 30
    )

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call
    session = report.fetch(:sessions).first
    row = session.fetch(:interactions).first

    assert_equal 60_000, session.fetch(:active_duration_ms)
    assert_equal 3_000, session.fetch(:selected_prompt_bytes)
    assert_equal interaction.to_param, row.fetch(:id)
    assert_equal true, row.fetch(:persistent_session_requested)
    assert_equal true, row.fetch(:session_mapping_found)
    assert_equal true, row.fetch(:resume_attempted)
    assert_equal 90_000, row.fetch(:full_prompt_bytes)
    assert_equal "chaos 0.1.0 (abc1234)", row.fetch(:chaos_version)
    assert_equal "versioned invocation-local telemetry complete", row.fetch(:telemetry_state_reason)
  end

  test "excludes process cumulative usage and marks unsupported telemetry" do
    create_interaction!(
      started_at: @from + 10.minutes,
      session_id: "process-cumulative",
      telemetry_schema_version: 1,
      usage_scope: "process_cumulative",
      usage_complete: true,
      cache_read_input_tokens: 50_000,
      provider_request_count: 20
    )
    create_interaction!(
      started_at: @from + 20.minutes,
      session_id: "future-schema",
      telemetry_schema_version: 2,
      usage_scope: "invocation",
      usage_complete: true,
      cache_read_input_tokens: 75_000,
      provider_request_count: 30
    )

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call

    assert_nil report.dig(:summary, :tokens, :cache_read_input_tokens)
    assert_nil report.dig(:summary, :provider_requests)
    assert_equal 2, report.dig(:summary, :token_unknown_rows, :cache_read_input_tokens)
    assert_equal 1, report.dig(:summary, :incomplete_usage_rows)
    assert_equal 1, report.dig(:summary, :unsupported_usage_rows)

    report.fetch(:sessions).each do |session|
      interaction = session.fetch(:interactions).first
      assert_nil interaction.fetch(:provider_request_count)
      assert_nil interaction.dig(:tokens, :cache_read_input_tokens)
    end
  end

  test "distinguishes legacy and unsupported Chaos telemetry" do
    create_interaction!(
      started_at: @from + 10.minutes,
      session_id: "legacy-chaos",
      chaos_telemetry_status: "legacy",
      usage_scope: nil,
      usage_complete: nil
    )
    create_interaction!(
      started_at: @from + 20.minutes,
      session_id: "future-chaos",
      chaos_telemetry_status: "unsupported",
      unsupported_chaos_telemetry_schema_version: 99,
      usage_scope: nil,
      usage_complete: nil
    )

    report = AgentRuntimeUsageReport.new(agent: @agent, from: @from, to: @to).call

    assert_equal 1, report.dig(:summary, :unavailable_usage_rows)
    assert_equal 1, report.dig(:summary, :unsupported_usage_rows)

    rows = report.fetch(:sessions).to_h do |session|
      [ session.fetch(:session_id), session.fetch(:interactions).first ]
    end
    assert_equal "unavailable", rows.fetch("legacy-chaos").fetch(:telemetry_state)
    assert_match(/legacy cumulative/, rows.fetch("legacy-chaos").fetch(:telemetry_state_reason))
    assert_equal "unsupported", rows.fetch("future-chaos").fetch(:telemetry_state)
    assert_match(/version 99/, rows.fetch("future-chaos").fetch(:telemetry_state_reason))
    assert_equal 99, rows.fetch("future-chaos").fetch(:unsupported_chaos_telemetry_schema_version)
  end

  test "rejects an inverted UTC window" do
    error = assert_raises(ArgumentError) do
      AgentRuntimeUsageReport.new(agent: @agent, from: @to, to: @from)
    end

    assert_match(/UTC report window/, error.message)
  end

  private

  def create_interaction!(**attributes)
    @agent.agent_runtime_interactions.create!(
      {
        trigger_kind: "conversation",
        started_at: @from,
        telemetry_schema_version: 1,
        usage_scope: "invocation",
        usage_complete: true,
        provider: "openai",
        model: "gpt-5-mini"
      }.merge(attributes)
    )
  end

end
