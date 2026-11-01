require "test_helper"

class AgentProviderAuthTest < ActiveSupport::TestCase

  test "Anthropic supports subscription account auth" do
    assert_includes Agent::OAUTH_ACCOUNT_PROVIDERS, "anthropic"
  end

  test "provider auth defaults to API key and records only display metadata" do
    agent = agents(:research_assistant)

    assert_equal "api_key", agent.provider_auth_mode("openai")

    agent.record_provider_connection!(
      "openai",
      email: "subscriber@example.com",
      plan: "Plus",
      status: "connected",
      connected_at: "2026-07-26T20:00:00Z",
      access_token: "must-not-be-stored"
    )

    assert_equal "oauth_account", agent.provider_auth_mode("openai")
    assert_equal(
      {
        "email" => "subscriber@example.com",
        "plan" => "Plus",
        "status" => "connected",
        "connected_at" => "2026-07-26T20:00:00Z"
      },
      agent.provider_connection("openai")
    )
    assert_not_includes agent.provider_connections.to_json, "must-not-be-stored"
  end

  test "disconnect clears display metadata and returns provider to API key mode" do
    agent = agents(:research_assistant)
    agent.record_provider_connection!("openai", status: "connected")

    agent.clear_provider_connection!("openai")

    assert_equal "api_key", agent.provider_auth_mode("openai")
    assert_empty agent.provider_connection("openai")
  end

  test "a house-marked expiry is audited once per transition" do
    agent = agents(:research_assistant)
    agent.record_provider_connection!("anthropic", status: "connected")
    assert_equal 0, AuditLog.where(auditable: agent).where("action LIKE 'agent.provider.%'").count

    assert_difference -> { AuditLog.where(action: Agent::PROVIDER_EXPIRED, auditable: agent).count }, 1 do
      agent.mark_provider_connection_status!("anthropic", "expired")
      agent.mark_provider_connection_status!("anthropic", "expired")
    end
    row = AuditLog.where(action: Agent::PROVIDER_EXPIRED, auditable: agent).last
    assert_equal({ "agent_id" => agent.id, "provider" => "anthropic", "previous_status" => "connected" }, row.data)
  end

end
