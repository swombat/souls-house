require "test_helper"

class ExpiredProviderSubscriptionsTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @user = users(:user_1)
  end

  test "counts expired subscription logins across every owned account and names them" do
    expire!(agents(:code_reviewer), "anthropic")
    expire!(agents(:other_account_agent), "gemini")

    summary = ExpiredProviderSubscriptions.summary_for(@user)

    assert_equal 2, summary[:total]
    assert_equal 1, summary[:accounts][accounts(:personal_account).to_param]
    assert_equal 1, summary[:accounts][accounts(:team_account).to_param]
    item = summary[:items].find { |i| i[:agent_id] == agents(:code_reviewer).to_param }
    assert_equal "Claude", item[:provider_name]
    assert_equal "Code Reviewer", item[:agent_name]
    assert_includes item[:url], "tab=settings"
  end

  test "connected, api-key and retired residents do not count, and reconnecting clears it" do
    agent = agents(:code_reviewer)
    agent.update!(provider_auth_modes: { "anthropic" => "oauth_account" },
                  provider_connections: { "anthropic" => { "status" => "connected" } })
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    agent.mark_provider_connection_status!("anthropic", "expired")
    assert_equal 1, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    agent.record_provider_connection!("anthropic", status: "connected")
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    agent.mark_provider_connection_status!("anthropic", "expired")
    agent.use_provider_auth_mode!("anthropic", "api_key")
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    expire!(agent, "anthropic")
    agent.update_columns(runtime: Agent::RuntimeAvailability::RETIRED_RUNTIMES.first)
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(@user)[:total]
  end

  test "accounts the person is not a confirmed member of are not counted" do
    expire!(agents(:code_reviewer), "anthropic")
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(users(:needsreset_user))[:total]
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(users(:unconfirmed_user))[:total]
  end

  test "members and admins of an account do not see its expired subscriptions, only owners" do
    expire!(agents(:other_account_agent), "gemini")
    member = users(:existing_user) # confirmed member of the team account
    assert_equal "member", memberships(:team_member).role
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(member)[:total]

    memberships(:team_member).update_columns(role: "admin")
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(member)[:total]

    memberships(:team_member).update_columns(role: "owner")
    assert_equal 1, ExpiredProviderSubscriptions.summary_for(member)[:total]
  end

  test "one resident with two expired providers counts twice, once per provider" do
    agents(:code_reviewer).update_columns(
      provider_auth_modes: { "anthropic" => "oauth_account", "gemini" => "oauth_account" },
      provider_connections: { "anthropic" => { "status" => "expired" }, "gemini" => { "status" => "expired" } }
    )
    summary = ExpiredProviderSubscriptions.summary_for(@user)
    assert_equal 2, summary[:total]
    assert_equal %w[Claude Google\ AI], summary[:items].map { |i| i[:provider_name] }.sort
  end

  test "subscription changes commit account refresh markers for a second confirmed account" do
    expire!(agents(:code_reviewer), "anthropic")
    agent = agents(:other_account_agent)
    channel = "Account:#{agent.account.to_param}"
    agent.record_provider_connection!("gemini", status: "connected")

    assert_broadcast_on(channel, action: "refresh") do
      agent.mark_provider_connection_status!("gemini", "expired")
    end
    assert_equal 2, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    assert_broadcast_on(channel, action: "refresh") do
      agent.record_provider_connection!("gemini", status: "connected")
    end
    assert_equal 1, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    agent.mark_provider_connection_status!("gemini", "expired")
    assert_broadcast_on(channel, action: "refresh") do
      agent.use_provider_auth_mode!("gemini", "api_key")
    end
    assert_equal 1, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    agent.record_provider_connection!("gemini", status: "expired")
    assert_broadcast_on(channel, action: "refresh") do
      agent.clear_provider_connection!("gemini")
    end
    assert_equal 1, ExpiredProviderSubscriptions.summary_for(@user)[:total]
  end

  test "retirement and actual destruction commit account markers and remove expired items" do
    expire!(agents(:code_reviewer), "anthropic")
    account = accounts(:team_account)
    channel = "Account:#{account.to_param}"
    retired = account.agents.create!(name: "Retiring resident", model_id: "openrouter/auto", runtime: "external")
    removed = account.agents.create!(name: "Removed resident", model_id: "openrouter/auto", runtime: "external")
    [ retired, removed ].each { |agent| agent.record_provider_connection!("gemini", status: "expired") }
    assert_equal 3, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    assert_broadcast_on(channel, action: "refresh") do
      retired.update!(runtime: "deprecated")
    end
    assert_equal 2, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    assert_broadcast_on(channel, action: "refresh") { removed.destroy! }
    summary = ExpiredProviderSubscriptions.summary_for(@user)
    assert_equal 1, summary[:total]
    assert_equal [ agents(:code_reviewer).to_param ], summary[:items].pluck(:agent_id)
  end

  test "a resident whose scheduled runs are failing adds one to the black count and is listed with its Runs tab" do
    agent = agents(:code_reviewer)
    streak = fail_streak!(agent, "authentication_error")

    summary = ExpiredProviderSubscriptions.summary_for(@user)
    assert_equal 1, summary[:total]
    assert_equal 1, summary[:accounts][agent.account.to_param]
    assert_empty summary[:items]
    item = summary[:failing].sole
    assert_equal "Code Reviewer", item[:agent_name]
    assert_equal "the run's output looked like an authentication error", item[:cause]
    assert_includes item[:url], "tab=interactions"

    expire!(agent, "anthropic")
    assert_equal 2, ExpiredProviderSubscriptions.summary_for(@user)[:total], "an expired login and failing runs are two problems"

    AuditLog.create!(user: nil, account: agent.account, action: ScheduledRunFailureNotice::RECOVERED, auditable: agent,
      data: { streak_id: streak.id })
    summary = ExpiredProviderSubscriptions.summary_for(@user)
    assert_empty summary[:failing]
    assert_equal 1, summary[:total]
  end

  test "failing residents are shown to owners only, and not while switched off, retired or asleep for billing" do
    agent = agents(:other_account_agent)
    fail_streak!(agent)
    member = users(:existing_user)
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(member)[:total]
    assert_equal 1, ExpiredProviderSubscriptions.summary_for(@user)[:failing].size

    agent.update_columns(active: false)
    assert_empty ExpiredProviderSubscriptions.summary_for(@user)[:failing]
    agent.update_columns(active: true, runtime: Agent::RuntimeAvailability::RETIRED_RUNTIMES.first)
    assert_empty ExpiredProviderSubscriptions.summary_for(@user)[:failing]
    agent.update_columns(runtime: "external")
    ResidentEntitlement.create!(agent: agent, account: agent.account, source: "stripe", state: "held", held_at: Time.current, tier: "conversation")
    assert_empty ExpiredProviderSubscriptions.summary_for(@user)[:failing]
  end

  private

  def expire!(agent, provider)
    agent.update_columns(
      provider_auth_modes: { provider => "oauth_account" },
      provider_connections: { provider => { "status" => "expired", "email" => "x@example.com" } }
    )
  end

  def fail_streak!(agent, category = "runtime_error")
    AuditLog.create!(user: nil, account: agent.account, action: ScheduledRunFailureNotice::FAILING, auditable: agent,
      data: { count: 2, category: category })
  end

end
