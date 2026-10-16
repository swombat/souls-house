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

  test "room activity streams per accessible account" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "RoomActivity", id: @account.obfuscated_id
    assert subscription.confirmed?
    assert_has_stream "RoomActivity:#{@account.obfuscated_id}"
  end

  test "room activity of an inaccessible account is rejected" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "RoomActivity", id: accounts(:existing_user_account).obfuscated_id
    assert subscription.rejected?
  end

  test "field activity streams only for the accessible account" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "FieldActivity", id: @account.obfuscated_id

    assert subscription.confirmed?
    assert_equal [ "FieldActivity:#{@account.obfuscated_id}" ], subscription.streams
  end

  test "field activity of another account is rejected" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "FieldActivity", id: accounts(:existing_user_account).obfuscated_id

    assert subscription.rejected?
    assert_no_streams
  end

  test "field activity rejects pending account membership" do
    stub_connection current_user: users(:unconfirmed_user), current_app_session: nil
    subscribe channel: "SyncChannel", model: "FieldActivity", id: accounts(:another_team).obfuscated_id

    assert subscription.rejected?
    assert_no_streams
  end

  test "field activity rejects native app connections" do
    client = Doorkeeper::Application.create!(name: "App", uid: "field-sync-refusal",
      redirect_uri: "https://example.com/cb", scopes: "chat", confidential: false)
    stub_connection current_user: @user, current_app_session: AppSession.create!(user: @user, oauth_application: client)
    subscribe channel: "SyncChannel", model: "FieldActivity", id: @account.obfuscated_id

    assert subscription.rejected?
    assert_no_streams
  end

  test "field activity rejects all even for site administrators" do
    stub_connection current_user: @admin, current_app_session: nil
    subscribe channel: "SyncChannel", model: "FieldActivity", id: "all"

    assert subscription.rejected?
    assert_no_streams
  end

  test "field activity rejects collection subscriptions" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "FieldActivity", id: "#{@account.obfuscated_id}:whiteboards"

    assert subscription.rejected?
    assert_no_streams
  end

  test "integration status subscribes only to the accessible account marker" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "IntegrationStatus", id: @account.to_param

    assert subscription.confirmed?
    assert_equal [ "IntegrationStatus:#{@account.to_param}" ], subscription.streams
  end

  test "integration status rejects inaccessible accounts" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "IntegrationStatus", id: accounts(:existing_user_account).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "integration status rejects pending membership" do
    stub_connection current_user: users(:unconfirmed_user), current_app_session: nil
    subscribe channel: "SyncChannel", model: "IntegrationStatus", id: accounts(:another_team).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "integration status rejects native connections" do
    client = Doorkeeper::Application.create!(name: "App", uid: "integration-sync-refusal",
      redirect_uri: "https://example.com/cb", scopes: "chat", confidential: false)
    stub_connection current_user: @user, current_app_session: AppSession.create!(user: @user, oauth_application: client)
    subscribe channel: "SyncChannel", model: "IntegrationStatus", id: @account.to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "integration status rejects all even for administrators" do
    stub_connection current_user: @admin, current_app_session: nil
    subscribe channel: "SyncChannel", model: "IntegrationStatus", id: "all"
    assert subscription.rejected?
    assert_no_streams
  end

  test "integration status rejects collections and direct connection subscriptions" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "IntegrationStatus", id: "#{@account.to_param}:service_connections"
    assert subscription.rejected?
    assert_no_streams
  end

  test "service connection is not a directly subscribable model" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe channel: "SyncChannel", model: "ServiceConnection", id: "svc_1"
    assert subscription.rejected?
    assert_no_streams
  end

end
