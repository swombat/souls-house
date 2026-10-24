require "test_helper"

class RhythmActivityChannelTest < ActionCable::Channel::TestCase

  tests SyncChannel

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    stub_connection current_user: @user, current_app_session: nil
  end

  test "confirmed members subscribe only to the account marker stream" do
    subscribe model: "RhythmActivity", id: @account.obfuscated_id

    assert subscription.confirmed?
    assert_equal [ "RhythmActivity:#{@account.obfuscated_id}" ], subscription.streams
  end

  test "foreign accounts are rejected" do
    subscribe model: "RhythmActivity", id: accounts(:existing_user_account).obfuscated_id

    assert subscription.rejected?
    assert_no_streams
  end

  test "pending account membership is rejected" do
    stub_connection current_user: users(:unconfirmed_user), current_app_session: nil
    subscribe model: "RhythmActivity", id: accounts(:another_team).obfuscated_id

    assert subscription.rejected?
    assert_no_streams
  end

  test "site administrators retain normal direct account access" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "RhythmActivity", id: @account.obfuscated_id

    assert subscription.confirmed?
    assert_equal [ "RhythmActivity:#{@account.obfuscated_id}" ], subscription.streams
  end

  test "all is rejected even for site administrators" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "RhythmActivity", id: "all"

    assert subscription.rejected?
    assert_no_streams
  end

  %w[agents chats rhythms occurrences].each do |collection|
    test "#{collection} collection expansion is rejected" do
      subscribe model: "RhythmActivity", id: "#{@account.obfuscated_id}:#{collection}"

      assert subscription.rejected?
      assert_no_streams
    end
  end

  test "native app sessions are rejected" do
    client = Doorkeeper::Application.create!(name: "Rhythm test", uid: "rhythm-sync-refusal",
      redirect_uri: "https://example.com/cb", scopes: "chat", confidential: false)
    stub_connection current_user: @user, current_app_session: AppSession.create!(user: @user, oauth_application: client)
    subscribe model: "RhythmActivity", id: @account.obfuscated_id

    assert subscription.rejected?
    assert_no_streams
  end

  test "adding activity access does not expose direct rhythm subscriptions" do
    subscribe model: "Rhythm", id: @account.obfuscated_id

    assert subscription.rejected?
    assert_no_streams
  end

end
