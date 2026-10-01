require "test_helper"

class SyncChannelTest < ActionCable::Channel::TestCase

  def setup
    @user = users(:user_1)
    @admin = users(:site_admin_user)
    @account = accounts(:personal_account)
  end

  test "subscribes to accessible account" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "Account", id: @account.obfuscated_id

    assert subscription.confirmed?
    assert_has_stream "Account:#{@account.obfuscated_id}"
  end

  test "rejects inaccessible account" do
    other_user = users(:existing_user)
    other_account = accounts(:existing_user_account)

    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "Account", id: other_account.obfuscated_id

    assert subscription.rejected?
  end

  test "admin can subscribe to all accounts" do
    stub_connection current_user: @admin, current_app_session: nil
    subscribe channel: "SyncChannel", model: "Account", id: "all"

    assert subscription.confirmed?
    assert_has_stream "Account:all"
  end

  test "non-admin cannot subscribe to all accounts" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "Account", id: "all"

    assert subscription.rejected?
  end

  test "rejects invalid model class" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "InvalidModel", id: "test"

    assert subscription.rejected?
  end

  test "rejects subscription without model param" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", id: "test"

    assert subscription.rejected?
  end

  test "rejects unapproved collection subscriptions" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "Account", id: "#{@account.obfuscated_id}:destroy"

    assert subscription.rejected?
  end

  test "rejects native-app connections, whose stream is AppSyncChannel" do
    client = Doorkeeper::Application.create!(name: "App", uid: "sync-refusal", redirect_uri: "https://souls.house/cb", scopes: "chat", confidential: false)
    stub_connection current_user: @user, current_app_session: AppSession.create!(user: @user, oauth_application: client)
    subscribe channel: "SyncChannel", model: "Account", id: @account.obfuscated_id

    assert subscription.rejected?
  end

  test "reply attention stream is private to its human even for administrators" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "ReplyAttention", id: @user.to_param
    assert subscription.confirmed?
    assert_has_stream "ReplyAttention:#{@user.to_param}"
  end

  test "administrators cannot subscribe to another humans reply attention" do
    stub_connection current_user: @admin, current_app_session: nil
    subscribe channel: "SyncChannel", model: "ReplyAttention", id: @user.to_param
    assert subscription.rejected?
  end

end
