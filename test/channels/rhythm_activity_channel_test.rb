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

  test "adding activity access does not expose direct rhythm subscriptions" do
    subscribe model: "Rhythm", id: @account.obfuscated_id

    assert subscription.rejected?
    assert_no_streams
  end

end
