require "test_helper"

class FieldVoiceActivityChannelTest < ActionCable::Channel::TestCase

  tests SyncChannel

  test "confirmed member reads the narrow account stream" do
    stub_connection current_user: users(:user_1), current_app_session: nil
    subscribe model: "FieldVoiceActivity", id: accounts(:team_account).to_param
    assert subscription.confirmed?
    assert_equal [ "FieldVoiceActivity:#{accounts(:team_account).to_param}" ], subscription.streams
  end

  test "site administrator can read a specific account" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "FieldVoiceActivity", id: accounts(:team_account).to_param
    assert subscription.confirmed?
    assert_equal [ "FieldVoiceActivity:#{accounts(:team_account).to_param}" ], subscription.streams
  end

  test "outsider is denied" do
    stub_connection current_user: users(:regular_user), current_app_session: nil
    subscribe model: "FieldVoiceActivity", id: accounts(:team_account).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "pending membership is denied" do
    stub_connection current_user: users(:unconfirmed_user), current_app_session: nil
    subscribe model: "FieldVoiceActivity", id: accounts(:another_team).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "unauthenticated user is denied" do
    stub_connection current_user: nil, current_app_session: nil
    subscribe model: "FieldVoiceActivity", id: accounts(:team_account).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "native app connection is denied" do
    stub_connection current_user: users(:user_1), current_app_session: Object.new
    subscribe model: "FieldVoiceActivity", id: accounts(:team_account).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "all is denied even to site administrators" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "FieldVoiceActivity", id: "all"
    assert subscription.rejected?
    assert_no_streams
  end

  test "collections are denied" do
    stub_connection current_user: users(:user_1), current_app_session: nil
    subscribe model: "FieldVoiceActivity", id: "#{accounts(:team_account).to_param}:field_voices"
    assert subscription.rejected?
    assert_no_streams
  end

  test "a voice id does not grant access to a foreign account roster" do
    voice = accounts(:existing_user_account).field_voices.create!(name: "Foreign synthetic voice")
    stub_connection current_user: users(:user_1), current_app_session: nil
    subscribe model: "FieldVoiceActivity", id: voice.account.to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "voice records are not directly subscribable" do
    voice = accounts(:team_account).field_voices.create!(name: "Synthetic voice")
    stub_connection current_user: users(:user_1), current_app_session: nil
    subscribe model: "FieldVoice", id: voice.to_param
    assert subscription.rejected?
    assert_no_streams
  end

end
