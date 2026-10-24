require "test_helper"

class ExpiredSubscriptionsSyncTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @personal = agents(:code_reviewer)
    @team = agents(:other_account_agent)
    [ @personal, @team ].each { |agent| agent.record_provider_connection!("anthropic", status: "expired") }
  end

  test "authorized partial refetch aggregates confirmed accounts but excludes pending and inaccessible accounts" do
    sign_in(@user)
    memberships(:team_admin).update!(confirmed_at: nil)
    pending = expired_agent(accounts(:another_team))
    inaccessible = expired_agent(accounts(:existing_user_account))

    summary = refetch_summary

    assert_equal 2, summary.fetch("total")
    assert_equal [ @personal.to_param, @team.to_param ].sort, summary.fetch("items").pluck("agent_id").sort
    assert_equal(
      { @personal.account.to_param => 1, @team.account.to_param => 1 },
      summary.fetch("accounts")
    )
    assert_not_includes summary.fetch("items").pluck("agent_id"), pending.to_param
    assert_not_includes summary.fetch("items").pluck("agent_id"), inaccessible.to_param

    # The same partial reload used after an Account marker must read fresh DB state.
    @team.record_provider_connection!("anthropic", status: "connected")
    summary = refetch_summary
    assert_equal 1, summary.fetch("total")
    assert_equal [ @personal.to_param ], summary.fetch("items").pluck("agent_id")
  end

  test "partial refetch drops an account whose membership was removed during the signed in session" do
    third = expired_agent(accounts(:another_team))
    sign_in(@user)
    assert_equal 3, refetch_summary.fetch("total")

    # This admin membership is removable, unlike the fixture's last-owner membership.
    memberships(:team_admin).destroy!

    summary = refetch_summary
    assert_equal 2, summary.fetch("total")
    assert_not_includes summary.fetch("accounts").keys, third.account.to_param
    assert_not_includes summary.fetch("items").pluck("agent_id"), third.to_param
  end

  test "site admin channel access does not widen the partial summary beyond confirmed memberships" do
    admin = users(:site_admin_user)
    own = expired_agent(accounts(:site_admin_account))
    pending = accounts(:team_account).add_user!(admin)
    assert_not pending.confirmed?
    # SyncChannel authorizes Account streams through this method, even for nonmembers.
    assert accounts(:team_account).accessible_by?(admin)
    assert accounts(:personal_account).accessible_by?(admin)
    sign_in(admin)

    summary = refetch_summary
    assert_equal 1, summary.fetch("total")
    assert_equal [ own.to_param ], summary.fetch("items").pluck("agent_id")
    assert_equal({ own.account.to_param => 1 }, summary.fetch("accounts"))

    pending.confirm!
    summary = refetch_summary
    assert_equal 2, summary.fetch("total")
    assert_equal [ own.to_param, @team.to_param ].sort, summary.fetch("items").pluck("agent_id").sort
  end

  private

  def sign_in(user)
    post login_path, params: { email_address: user.email_address, password: "password123" }
    assert_redirected_to root_path
    # Use the version actually served to this browser, not a freshly computed
    # Vite digest (the shared checkout's frontend can change during this test).
    get edit_user_path
    assert_response :success
    @page_version = inertia_props.fetch("version")
  end

  def expired_agent(account)
    agent = account.agents.create!(name: "Expired resident", model_id: "openrouter/auto", runtime: "external")
    agent.record_provider_connection!("gemini", status: "expired")
    agent
  end

  def refetch_summary
    get edit_user_path, headers: {
      "X-Inertia" => "true",
      "X-Inertia-Version" => @page_version,
      "X-Inertia-Partial-Component" => "user/edit",
      "X-Inertia-Partial-Data" => "expired_subscriptions"
    }
    assert_response :success
    page = response.parsed_body
    assert_equal "user/edit", page.fetch("component")
    props = page.fetch("props")
    assert props.key?("expired_subscriptions")
    assert_not props.key?("timezones"), "the request must be a partial reload, not a full page"
    props.fetch("expired_subscriptions")
  end

end
