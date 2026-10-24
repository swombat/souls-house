require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceLifecycleChannelTest < ActionCable::Channel::TestCase

  include FieldRecordingHelpers
  tests SyncChannel

  setup do
    @account = accounts(:team_account)
    @recording = long_ready_recording(account: @account, user: users(:user_1))
  end

  test "confirmed member and site administrator can read only the scoped recording stream" do
    [ users(:user_1), users(:site_admin_user) ].each do |user|
      stub_connection current_user: user, current_app_session: nil
      subscribe model: "FieldRecording", id: @recording.to_param
      assert subscription.confirmed?
      assert_equal [ "FieldRecording:#{@recording.to_param}" ], subscription.streams
      unsubscribe
    end
  end

  test "outsider pending member foreign recording and native sessions cannot subscribe" do
    [ users(:regular_user), users(:unconfirmed_user) ].each do |user|
      stub_connection current_user: user, current_app_session: nil
      subscribe model: "FieldRecording", id: @recording.to_param
      assert subscription.rejected?
      assert_no_streams
    end
    foreign = long_ready_recording(account: accounts(:existing_user_account), user: users(:existing_user))
    stub_connection current_user: users(:user_1), current_app_session: nil
    subscribe model: "FieldRecording", id: foreign.to_param
    assert subscription.rejected?
    assert_no_streams
    stub_connection current_user: users(:user_1), current_app_session: Object.new
    subscribe model: "FieldRecording", id: @recording.to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "no all collection print or voice sample subscriptions even for an administrator" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    [
      [ "FieldRecording", "all" ], [ "FieldRecording", "#{@recording.to_param}:speakers" ],
      [ "FieldVoiceprint", @recording.to_param ], [ "FieldVoiceSample", @recording.to_param ]
    ].each do |model, id|
      subscribe(model:, id:)
      assert subscription.rejected?
      assert_no_streams
    end
  end

end
