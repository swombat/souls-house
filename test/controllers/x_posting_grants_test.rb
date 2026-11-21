require "test_helper"

# The per-resident X posting switch on the Integrations page. X posting is
# its own record (XIntegration), not a service connection, so it has its own
# row there and its own grants.
class XPostingGrantsTest < ActionDispatch::IntegrationTest

  setup do
    @owner = users(:user_1)
    @account = accounts(:personal_account)
    @granted = agents(:research_assistant)
    @ungranted = agents(:code_reviewer)
    @integration = @account.create_x_integration!(
      enabled: true, x_username: "househandle", client_id: "own-cid", client_secret: "own-secret",
      access_token: "live-token", refresh_token: "refresh-1", token_expires_at: 2.hours.from_now
    )
    @integration.x_posting_grants.create!(agent: @granted)
  end

  test "the Integrations page lists X with a switch per resident" do
    sign_in @owner

    get account_integrations_path(@account)

    assert_response :success
    x = inertia_props["props"]["x_posting"]
    assert_equal "househandle", x["x_username"]
    assert x["connected"]
    assert x["enabled"]
    assert x["can_manage"]
    residents = x["residents"].index_by { |resident| resident["id"] }
    assert residents[@granted.to_param]["enabled"]
    assert_not residents[@ungranted.to_param]["enabled"]
  end

  test "an account that has not started on X has no X row" do
    @integration.destroy!
    sign_in @owner

    get account_integrations_path(@account)

    assert_nil inertia_props["props"]["x_posting"]
  end

  test "an account admin switches a resident on and off" do
    sign_in @owner

    patch grant_x_integration_path(account_id: @account.to_param), params: { agent_id: @ungranted.to_param, enabled: "true" }
    assert @integration.granted_to?(@ungranted)

    patch grant_x_integration_path(account_id: @account.to_param), params: { agent_id: @ungranted.to_param, enabled: "true" }
    assert_equal 1, @integration.x_posting_grants.where(agent: @ungranted).count

    patch grant_x_integration_path(account_id: @account.to_param), params: { agent_id: @granted.to_param, enabled: "false" }
    assert_not @integration.granted_to?(@granted)
    assert_redirected_to account_integrations_path(@account)
  end

  test "a member who is not an admin cannot switch residents" do
    team = accounts(:team_account)
    team_x = team.create_x_integration!(enabled: true, client_id: "own-cid", client_secret: "own-secret")
    sign_in users(:existing_user)

    assert_no_difference -> { XPostingGrant.count } do
      patch grant_x_integration_path(account_id: team.to_param), params: { agent_id: @ungranted.to_param, enabled: "true" }
    end

    assert_redirected_to account_integrations_path(team)
    assert_equal "Only account admins can change the X connection", flash[:alert]
    assert_empty team_x.x_posting_grants
  end

  test "a resident of another account cannot be switched on" do
    sign_in @owner
    stranger = agents(:other_account_agent)

    patch grant_x_integration_path(account_id: @account.to_param), params: { agent_id: stranger.to_param, enabled: "true" }

    assert_response :not_found
    assert_not @integration.granted_to?(stranger)
  end

  test "a grant can only join a resident to its own account's X handle" do
    grant = XPostingGrant.new(x_integration: @integration, agent: agents(:other_account_agent))

    assert_not grant.valid?
  end

end
