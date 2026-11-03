require "test_helper"
require "webmock/minitest"

class ExternalAgentWakeRequestTest < ActiveSupport::TestCase

  test "wake request invites self-directed work and clear commits" do
    agent = agents(:research_assistant)
    request = ExternalAgentWakeRequest.new(agent: agent)
    text = request.send(:request_text)

    assert_includes text, "scheduled self-directed session"
    assert_includes text, "Current time:"
    assert_includes text, "choose to do nothing"
    assert_includes text, "souls.house is inviting you to wake"
    assert_includes text, "/usr/local/share/helixkit-agent/soulshouse-api.md"
    assert_includes text, "Do something else you freely choose"
    assert_includes text, "Keep it reasonable"
    assert_includes text, "Do not consume lots of tokens"
    assert_includes text, "very clear commit message"
    assert_includes text, "identity/soul.md as protected"
    assert_includes text, "Cross-room attention"
    assert_includes text, "No current attention candidates were found"
  end

  test "persistent wake sessions default on but an explicit fresh choice remains off" do
    assert Agent.new.persistent_wake_session?
    assert_not Agent.new(persistent_wake_session: false).persistent_wake_session?
  end

  test "heartbeat wakes default to twice daily" do
    agent = agents(:research_assistant)

    assert_equal 2, agent.heartbeat_wakes_per_day
  end

  test "wake request includes active house notices" do
    agent = agents(:research_assistant)
    Notice.create!(
      scope: "account",
      account: agent.account,
      notice_type: "announcement",
      body: "Wake notice",
      expires_at: 1.day.from_now
    )

    assert_includes ExternalAgentWakeRequest.new(agent: agent).send(:request_text), "Wake notice"
  end

  test "wake triggers carry the agent session policy" do
    agent = agents(:research_assistant)
    agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0,
      persistent_wake_session: true,
      session_idle_timeout_minutes: 30,
      turn_timeout_minutes: 1440
    )
    # Scheduled runs are refused before dispatch without a usable credential
    # (InferenceAvailability); fund the route so the trigger itself is tested.
    agent.account.update!(openrouter_api_key: "test-router")
    stub = stub_request(:post, "https://agent.example.com/trigger")
      .with do |request|
        body = JSON.parse(request.body)
        body["timeout_secs"] == 86400 &&
          body["persistent_session"] == true &&
          body.dig("session_policy", "idle_timeout_secs") == 1800 &&
          body.dig("session_policy", "max_age_secs") == 14_400
      end
      .to_return(status: 200, body: { status: "ok" }.to_json)

    ExternalAgentWakeRequest.new(agent: agent).send(:perform)

    assert_requested stub
  end

  test "a resident with no usable credential gets a needs_setup run and no request to its runtime" do
    agent = agents(:research_assistant)
    agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0,
      model_id: "x-ai/grok-4.7",
      provider_auth_modes: {},
      provider_connections: {}
    )
    agent.account.update_columns(use_system_ai_credentials: false)
    Account::AI_PROVIDERS.each_key { |provider| agent.account.update!("#{provider}_api_key" => nil) }
    stub = stub_request(:post, "https://agent.example.com/trigger")

    assert_difference "AgentRuntimeInteraction.count", 1 do
      ExternalAgentWakeRequest.new(agent: agent).send(:perform)
    end

    assert_not_requested stub
    run = AgentRuntimeInteraction.last
    assert_equal "wake", run.trigger_kind
    assert_equal "error", run.runtime_status
    assert_equal :failure, run.streak_outcome
    assert_equal "needs_setup", run.failure_category
    assert_equal Agents::InferenceAvailability::MISSING_CREDENTIALS_MESSAGE, run.response_body["error"]
  end

end
