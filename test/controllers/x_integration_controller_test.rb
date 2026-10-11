require "test_helper"

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
    assert_equal 20, props.dig("integration", "daily_post_limit")

    with_x_credentials do
      post x_integration_path(account_id: @account.to_param)
    end
    assert_response :redirect
    assert_not @account.reload.x_integration.enabled?
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
