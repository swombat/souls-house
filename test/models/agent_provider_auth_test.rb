require "test_helper"

class AgentProviderAuthTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

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

  test "the first sight of an expired sign-in emails each confirmed owner and admin once (#844)" do
    agent = agents(:other_account_agent)
    member = memberships(:team_member) # a plain member of the same account
    agent.record_provider_connection!("anthropic", status: "connected")
    owners = agent.account.memberships.confirmed.owners.map(&:user)
    assert owners.any?

    assert_enqueued_emails owners.size do
      agent.mark_provider_connection_status!("anthropic", "expired")
      agent.mark_provider_connection_status!("anthropic", "expired")
    end

    member.update_columns(role: "admin")
    agent.mark_provider_connection_status!("anthropic", "connected")
    assert_enqueued_emails owners.size + 1 do
      agent.mark_provider_connection_status!("anthropic", "expired")
    end

    mail = ResidentHealthMailer.provider_sign_in_expired(agent, "anthropic", member.user)
    assert_equal [ member.user.email_address ], mail.to
    assert_equal "#{agent.name}'s Claude sign-in needs reconnecting", mail.subject
    text = mail.text_part.body.to_s
    assert_includes text, "tab=settings"
    assert_includes text, "detected an authentication failure"
    assert_not_includes text, "twice"
  end

  test "a switched-off resident's expired sign-in emails nobody" do
    agent = agents(:research_assistant)
    agent.record_provider_connection!("anthropic", status: "connected")
    agent.update_columns(active: false)

    assert_no_enqueued_emails do
      agent.mark_provider_connection_status!("anthropic", "expired")
    end
  end

end
