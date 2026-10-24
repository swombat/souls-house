require "test_helper"

class RoomNavigationChannelTest < ActionCable::Channel::TestCase

  tests SyncChannel

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    stub_connection current_user: @user, current_app_session: nil
  end

  test "confirmed account member subscribes to the narrow stream" do
    subscribe model: "RoomNavigation", id: @account.to_param
    assert subscription.confirmed?
    assert_has_stream "RoomNavigation:#{@account.to_param}"
    assert_has_no_stream "Account:#{@account.to_param}"
    assert_has_no_stream "RoomActivity:#{@account.to_param}"
  end

  test "inaccessible account is rejected" do
    subscribe model: "RoomNavigation", id: accounts(:existing_user_account).to_param
    assert subscription.rejected?
  end

  test "pending membership is rejected" do
    memberships(:team_admin).update!(confirmed_at: nil)
    subscribe model: "RoomNavigation", id: accounts(:another_team).to_param
    assert subscription.rejected?
  end

  test "removed membership is rejected on a new subscription" do
    memberships(:team_admin).destroy!
    subscribe model: "RoomNavigation", id: accounts(:another_team).to_param
    assert subscription.rejected?
  end

  test "site administrator can subscribe to an account without membership" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "RoomNavigation", id: @account.to_param
    assert subscription.confirmed?
    assert_has_stream "RoomNavigation:#{@account.to_param}"
  end

  test "all accounts is rejected even for a site administrator" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "RoomNavigation", id: "all"
    assert subscription.rejected?
  end

  test "collections are rejected" do
    subscribe model: "RoomNavigation", id: "#{@account.to_param}:rooms"
    assert subscription.rejected?
  end

  test "native-app connections cannot use the web navigation stream" do
    client = Doorkeeper::Application.create!(name: "App", uid: "room-navigation-refusal", redirect_uri: "https://souls.house/cb", scopes: "chat", confidential: false)
    app_session = AppSession.create!(user: @user, oauth_application: client)
    stub_connection current_user: @user, current_app_session: app_session
    subscribe model: "RoomNavigation", id: @account.to_param
    assert subscription.rejected?
  end

end
