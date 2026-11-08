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

  test "all accounts is rejected even for a site administrator" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "RoomNavigation", id: "all"
    assert subscription.rejected?
  end

  test "collections are rejected" do
    subscribe model: "RoomNavigation", id: "#{@account.to_param}:rooms"
    assert subscription.rejected?
  end

end
