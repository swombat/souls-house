require "test_helper"
require "webmock/minitest"

class XIntegrationControllerTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:team_account)
    @owner = users(:user_1)
    @member = users(:existing_user)
  end

  test "the page is for the account named in account_id and new connections start with posting off" do
    sign_in(@owner)

    get x_integration_path(account_id: @account.to_param)

    assert_response :success
    props = inertia_props["props"]
    assert_equal @account.to_param, props["account_id"]
    assert props["can_manage"]
    assert_nil props.dig("integration", "app_source")
    assert_not props.dig("integration", "house_app_allowed")
    assert_not props["integration"].key?("daily_post_limit")

    @account.create_x_integration!(enabled: false, client_id: "own-cid", client_secret: "own-secret")
    post x_integration_path(account_id: @account.to_param)
    assert_response :redirect
    assert_match %r{\Ahttps://x\.com/i/oauth2/authorize\?.*client_id=own-cid}, response.location
    assert_not @account.reload.x_integration.enabled?
  end

  test "an account without a site admin cannot connect through the house app" do
    sign_in(@owner)

    with_x_credentials do
      post x_integration_path(account_id: @account.to_param)
    end

    assert_redirected_to x_integration_path(account_id: @account.to_param)
    assert_equal "Add this account's X app before connecting", flash[:alert]
  end

  test "an account with a site admin connects through the house app" do
    @account.memberships.create!(user: users(:site_admin_user), role: "member", confirmed_at: Time.current)
    sign_in(@owner)

    with_x_credentials do
      get x_integration_path(account_id: @account.to_param)
      assert_equal "house", inertia_props.dig("props", "integration", "app_source")

      post x_integration_path(account_id: @account.to_param)
    end

    assert_match %r{client_id=cid}, response.location
  end

  test "an account a site admin granted the house app connects through it" do
    @account.update!(x_posting_house_app: true)
    sign_in(@owner)

    with_x_credentials do
      get x_integration_path(account_id: @account.to_param)
      assert_equal "house", inertia_props.dig("props", "integration", "app_source")
      assert_equal "granted", inertia_props.dig("props", "integration", "house_app_reason")

      post x_integration_path(account_id: @account.to_param)
    end

    assert_match %r{client_id=cid}, response.location
  end

  test "only a site admin grants or withdraws the house X app, and withdrawing disconnects" do
    integration = XIntegration.create!(account: @account, enabled: true,
      access_token: "t", refresh_token: "rt", token_expires_at: 1.hour.from_now)
    sign_in(@owner)
    patch x_posting_house_app_admin_account_path(@account), params: { account: { x_posting_house_app: true } }
    assert_not @account.reload.x_posting_house_app?

    delete logout_path
    sign_in(users(:site_admin_user))
    patch x_posting_house_app_admin_account_path(@account), params: { account: { x_posting_house_app: true } }
    assert @account.reload.x_posting_house_app?
    assert integration.reload.connected?

    patch x_posting_house_app_admin_account_path(@account), params: { account: { x_posting_house_app: false } }
    assert_not @account.reload.x_posting_house_app?
    assert_not integration.reload.connected?
    assert_not integration.enabled?
  end

  test "an admin saves the account's own X app; the secret never comes back to the page" do
    sign_in(@owner)

    put app_x_integration_path(account_id: @account.to_param), params: { x_app: { client_id: "own-cid", client_secret: "own-secret" } }

    assert_redirected_to x_integration_path(account_id: @account.to_param)
    integration = @account.reload.x_integration
    assert_equal "own-cid", integration.client_id
    assert_equal "own-secret", integration.client_secret

    get x_integration_path(account_id: @account.to_param)
    assert_equal "own", inertia_props.dig("props", "integration", "app_source")
    assert_equal "own-cid", inertia_props.dig("props", "integration", "own_client_id")
    assert_not_includes response.body, "own-secret"

    delete app_x_integration_path(account_id: @account.to_param)
    assert_not integration.reload.own_app?
  end

  test "an incomplete X app is refused with a message" do
    sign_in(@owner)

    put app_x_integration_path(account_id: @account.to_param), params: { x_app: { client_id: "own-cid", client_secret: "" } }

    assert_redirected_to x_integration_path(account_id: @account.to_param)
    assert_match "client secret", flash[:alert]
    assert_not @account.reload.x_integration&.own_app?
  end

  test "a callback after the app was replaced keeps no tokens, even with a valid state" do
    @account.create_x_integration!(enabled: false, client_id: "app-a", client_secret: "secret-a")
    sign_in(@owner)
    post x_integration_path(account_id: @account.to_param)
    state = Rack::Utils.parse_query(URI(response.location).query)["state"]

    put app_x_integration_path(account_id: @account.to_param), params: { x_app: { client_id: "app-b", client_secret: "secret-b" } }
    get callback_x_integration_path(state:, code: "code-for-a")

    assert_redirected_to x_integration_path(account_id: @account.to_param)
    assert_match "changed", flash[:alert]
    integration = @account.reload.x_integration
    assert_equal "app-b", integration.client_id
    assert_not integration.connected?
    assert_not_requested :post, "https://api.x.com/2/oauth2/token"
  end

  test "an ordinary member cannot set or remove the account's X app" do
    integration = @account.create_x_integration!(enabled: false, client_id: "own-cid", client_secret: "own-secret")
    sign_in(@member)

    put app_x_integration_path(account_id: @account.to_param), params: { x_app: { client_id: "theirs", client_secret: "theirs" } }
    delete app_x_integration_path(account_id: @account.to_param)

    assert_equal "own-cid", integration.reload.client_id
    assert integration.own_app?
  end

  test "an ordinary member can see the page but cannot switch posting on" do
    @account.create_x_integration!(enabled: false, access_token: "t", refresh_token: "r")
    sign_in(@member)

    get x_integration_path(account_id: @account.to_param)
    assert_response :success
    assert_not inertia_props.dig("props", "can_manage")

    patch x_integration_path(account_id: @account.to_param), params: { x_integration: { enabled: true } }

    assert_redirected_to x_integration_path(account_id: @account.to_param)
    assert_not @account.x_integration.reload.enabled?
  end

  test "an admin can switch posting on for the named account" do
    @account.create_x_integration!(enabled: false, access_token: "t", refresh_token: "r")
    sign_in(@owner)

    patch x_integration_path(account_id: @account.to_param), params: { x_integration: { enabled: true } }

    assert @account.x_integration.reload.enabled?
  end

  private

  def with_x_credentials(&block)
    credentials = Rails.application.credentials
    original = credentials.method(:dig)
    credentials.stub(:dig, ->(*keys) { keys.first == :x ? { client_id: "cid", client_secret: "csecret" }[keys.last] : original.call(*keys) }, &block)
  end

end
