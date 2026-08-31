require "test_helper"

class Admin::AgentRuntimeSessionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @site_admin = users(:site_admin_user)
    @regular_user = users(:regular_user)
  end

  test "requires authentication" do
    get admin_agent_runtime_path(@agent)

    assert_redirected_to login_path
  end

  test "site-wide session index requires authentication" do
    get admin_runtime_sessions_path

    assert_redirected_to login_path
  end

  test "requires a site administrator" do
    login_as(@regular_user)

    get admin_agent_runtime_path(@agent)

    assert_redirected_to root_path
  end

  test "site-wide session index requires a site administrator" do
    login_as(@regular_user)

    get admin_runtime_sessions_path

    assert_redirected_to root_path
  end

  test "renders sessions across accounts with weekly activity for site administrators" do
    other_agent = agents(:other_account_agent)
    @agent.agent_runtime_interactions.create!(
      trigger_kind: "conversation",
      session_id: "web-session",
      started_at: 20.minutes.ago,
      finished_at: 10.minutes.ago
    )
    other_agent.agent_runtime_interactions.create!(
      trigger_kind: "telegram",
      session_id: "telegram-session",
      started_at: 5.minutes.ago
    )
    login_as(@site_admin)

    get admin_runtime_sessions_path, params: { window: "1h" }

    assert_response :success
    assert_equal "admin/runtime-sessions", inertia_component
    props = inertia_shared_props.fetch("report")
    assert_equal "1h", props.fetch("window")
    assert_equal 2, props.dig("summary", "active_residents")
    assert_equal 2, props.dig("summary", "sessions")
    assert_equal 7, props.dig("activity", "days").size
    assert_equal [ "telegram-session", "web-session" ], props.fetch("sessions").map { |session| session["session_id"] }
    assert_not props.fetch("sessions").first.key?("request_text")
  end

  test "renders a safe UTC session report for site administrators" do
    interaction = @agent.agent_runtime_interactions.create!(
      trigger_kind: "conversation",
      session_id: "session-safe",
      started_at: Time.current,
      chaos_session_id: "chaos-safe",
      session_outcome: "resumed",
      prompt_mode: "delta",
      selected_prompt_bytes: 1_024,
      telemetry_schema_version: 1,
      usage_scope: "invocation",
      cache_read_input_tokens: 500,
      output_tokens: 20,
      provider_request_count: 2,
      usage_complete: true,
      request_text: "private prompt",
      stdout: "private output",
      full_invocation_text: "private identity and transcript"
    )
    login_as(@site_admin)

    get admin_agent_runtime_path(@agent)

    assert_response :success
    assert_equal "admin/agent-runtime-sessions", inertia_component
    props = inertia_shared_props
    assert_equal @agent.to_param, props.dig("agent", "id")
    assert_equal "UTC", props.dig("report", "window", "timezone")
    assert_equal 1, props.dig("report", "summary", "interactions")

    rendered_interaction = props.dig("report", "sessions", 0, "interactions", 0)
    assert_equal interaction.to_param, rendered_interaction["id"]
    assert_equal 500, rendered_interaction.dig("tokens", "cache_read_input_tokens")
    assert_equal "complete", rendered_interaction["telemetry_state"]
    assert_not rendered_interaction.key?("request_text")
    assert_not rendered_interaction.key?("stdout")
    assert_not rendered_interaction.key?("full_invocation_text")
    assert_not rendered_interaction.key?("response_body")
  end

  test "accepts an explicit UTC window" do
    login_as(@site_admin)

    get admin_agent_runtime_path(@agent), params: {
      from: "2026-07-18T10:00:00Z",
      to: "2026-07-18T12:00:00Z"
    }

    assert_response :success
    assert_equal "2026-07-18T10:00:00Z", inertia_shared_props.dig("filters", "from")
    assert_equal "2026-07-18T12:00:00Z", inertia_shared_props.dig("filters", "to")
  end

  test "normalizes a backwards UTC window instead of raising" do
    login_as(@site_admin)

    get admin_agent_runtime_path(@agent), params: {
      from: "2026-07-18T14:00:00Z",
      to: "2026-07-18T12:00:00Z"
    }

    assert_response :success
    assert_equal "2026-07-17T12:00:00Z", inertia_shared_props.dig("filters", "from")
    assert_equal "2026-07-18T12:00:00Z", inertia_shared_props.dig("filters", "to")
  end

  test "ignores malformed timestamp parameters" do
    login_as(@site_admin)

    get admin_agent_runtime_path(@agent), params: {
      from: { unexpected: "value" },
      to: "not-a-time"
    }

    assert_response :success
    from = Time.iso8601(inertia_shared_props.dig("filters", "from"))
    to = Time.iso8601(inertia_shared_props.dig("filters", "to"))
    assert_in_delta 24.hours, to - from, 1.second
  end

  test "limits reports to a 31 day UTC window" do
    login_as(@site_admin)

    get admin_agent_runtime_path(@agent), params: {
      from: "2026-01-01T00:00:00Z",
      to: "2026-07-18T12:00:00Z"
    }

    assert_response :success
    assert_equal "2026-06-17T12:00:00Z", inertia_shared_props.dig("filters", "from")
    assert_equal "2026-07-18T12:00:00Z", inertia_shared_props.dig("filters", "to")
  end

  test "applies report dimensions and selects a logical session timeline" do
    @agent.agent_runtime_interactions.create!(
      trigger_kind: "wake",
      session_id: "wake-session",
      started_at: Time.current,
      telemetry_schema_version: 1,
      usage_scope: "invocation",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-fable-5",
      session_outcome: "resumed"
    )
    @agent.agent_runtime_interactions.create!(
      trigger_kind: "conversation",
      session_id: "chat-session",
      started_at: Time.current,
      telemetry_schema_version: 1,
      usage_scope: "invocation",
      usage_complete: true,
      provider: "openai",
      model: "gpt-5.5",
      session_outcome: "fresh"
    )
    login_as(@site_admin)

    get admin_agent_runtime_path(@agent), params: {
      trigger_kind: "wake",
      provider: "anthropic",
      session_id: "wake-session"
    }

    assert_response :success
    props = inertia_shared_props
    assert_equal 1, props.dig("report", "summary", "interactions")
    assert_equal "wake-session", props.dig("report", "sessions", 0, "session_id")
    assert_equal "wake-session", props["selected_session_id"]
    assert_equal "wake", props.dig("filters", "trigger_kind")
    assert_equal "anthropic", props.dig("filters", "provider")
  end

  private

  def login_as(user)
    post login_path, params: {
      email_address: user.email_address,
      password: "password123"
    }
  end

end
