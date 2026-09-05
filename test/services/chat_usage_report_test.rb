require "test_helper"

class ChatUsageReportTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "deprecated")
    @chat = @agent.account.chats.create!(
      model_id: "openai/gpt-5.4",
      title: "Usage report",
      manual_responses: true,
      agent_ids: [ @agent.id ]
    )
  end

  test "groups message and runtime token categories by model" do
    @chat.messages.create!(
      role: "assistant",
      agent: @agent,
      content: "Inline response",
      model_id_string: "openai/gpt-5.4",
      input_tokens: 100,
      cache_creation_tokens: 20,
      cached_tokens: 30,
      output_tokens: 40,
      thinking_tokens: 10
    )
    AgentRuntimeInteraction.create!(
      agent: @agent,
      chat: @chat,
      trigger_kind: "conversation",
      started_at: Time.current,
      telemetry_schema_version: 1,
      chaos_telemetry_status: "detailed",
      usage_scope: "invocation",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-fable-5",
      uncached_input_tokens: 200,
      cache_creation_input_tokens: 50,
      cache_read_input_tokens: 500,
      output_tokens: 60,
      reasoning_output_tokens: 15
    )

    report = ChatUsageReport.new(chat: @chat).call

    assert_equal 2, report[:models].size
    assert report[:instrumentation_complete]
    assert_equal 300, report.dig(:totals, :uncached_input_tokens)
    assert_equal 530, report.dig(:totals, :cache_read_input_tokens)
    assert_equal 100, report.dig(:totals, :output_tokens)
    assert_equal "0.006125", report.dig(:estimated_cost, :amount_usd)
    assert_equal 1, report.dig(:estimated_cost, :interaction_count)
  end

  test "marks rows incomplete instead of treating missing categories as zero" do
    @chat.messages.create!(
      role: "assistant",
      agent: @agent,
      content: "Legacy response",
      model_id_string: "openai/gpt-5.4",
      input_tokens: 100,
      output_tokens: 40
    )

    report = ChatUsageReport.new(chat: @chat).call

    assert_not report[:instrumentation_complete]
    assert_equal 1, report[:incomplete_rows]
    assert_nil report.dig(:totals, :cache_read_input_tokens)
    assert_match(/Unknown values/, report[:instrumentation_note])
  end

  test "does not double count messages posted by externally hosted agents" do
    @agent.update!(runtime: "external")
    @chat.messages.create!(
      role: "assistant",
      agent: @agent,
      content: "Posted through the HelixKit API",
      model_id_string: "claude-fable-5",
      input_tokens: 200,
      output_tokens: 20
    )
    AgentRuntimeInteraction.create!(
      agent: @agent,
      chat: @chat,
      trigger_kind: "conversation",
      started_at: Time.current,
      telemetry_schema_version: 1,
      chaos_telemetry_status: "detailed",
      usage_scope: "trigger",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-fable-5",
      uncached_input_tokens: 200,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 20,
      reasoning_output_tokens: 0
    )

    report = ChatUsageReport.new(chat: @chat).call

    assert_equal 1, report[:row_count]
    assert_equal 200, report.dig(:totals, :uncached_input_tokens)
    assert_equal 20, report.dig(:totals, :output_tokens)
  end

  test "adds an unambiguously linked wake estimate to the conversation total" do
    started_at = 1.minute.ago
    @chat.messages.create!(
      role: "assistant",
      agent: @agent,
      content: "Posted during a wake",
      created_at: started_at + 10.seconds
    )
    AgentRuntimeInteraction.create!(
      agent: @agent,
      trigger_kind: "wake",
      started_at: started_at,
      finished_at: started_at + 20.seconds,
      telemetry_schema_version: 1,
      usage_scope: "trigger",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-sonnet-5",
      uncached_input_tokens: 1_000,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 25
    )

    report = ChatUsageReport.new(chat: @chat).call

    assert_equal "0.00225", report.dig(:estimated_cost, :amount_usd)
    assert_equal 1, report.dig(:estimated_cost, :interaction_count)
  end

  test "omits the estimated total when no interaction has an available estimate" do
    AgentRuntimeInteraction.create!(
      agent: @agent,
      chat: @chat,
      trigger_kind: "conversation",
      started_at: Time.current,
      telemetry_schema_version: nil,
      provider: "anthropic",
      model: "claude-sonnet-5"
    )

    report = ChatUsageReport.new(chat: @chat).call

    assert_nil report[:estimated_cost]
  end

  test "reports subscription estimates separately from applicable costs" do
    AgentRuntimeInteraction.create!(
      agent: @agent,
      chat: @chat,
      trigger_kind: "conversation",
      started_at: Time.current,
      telemetry_schema_version: 1,
      chaos_telemetry_status: "detailed",
      usage_scope: "invocation",
      usage_complete: true,
      provider: "openai",
      model: "gpt-5",
      provider_auth_mode: "oauth_account",
      uncached_input_tokens: 1_000,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 25
    )

    report = ChatUsageReport.new(chat: @chat).call

    assert_nil report.dig(:estimated_cost, :amount_usd)
    assert_equal "0.0015", report.dig(:estimated_cost, :subscription_estimate_usd)
    assert_equal 0, report.dig(:estimated_cost, :interaction_count)
    assert_equal 1, report.dig(:estimated_cost, :subscription_interaction_count)
  end

end
