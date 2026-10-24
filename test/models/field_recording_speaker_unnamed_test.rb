require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingSpeakerUnnamedTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  test "a recording's list entry counts the speakers still waiting for a name" do
    recording = long_ready_recording(account: @account, user: @user)
    speaker, _other = recording.speakers.to_a
    assert_equal 2, FieldItems.recording_json(recording.reload)[:unnamed_speakers]

    speaker.name_as!(@account.field_voices.create!(name: "Tomás"), by: @user)
    assert_equal 1, FieldItems.recording_json(recording.reload)[:unnamed_speakers]
  end

  test "a supplied transcript's real names are named; its generic labels are not" do
    recording = long_ready_recording(account: @account, user: @user)
    recording.update_columns(transcript_source: "supplied")
    real, generic = recording.speakers.to_a
    real.update_columns(label: "Anna")
    generic.update_columns(label: "Speaker B")

    assert_not real.reload.unnamed?
    assert generic.reload.unnamed?
  end

  test "a recording that isn't ready has nothing to name" do
    recording = queued_recording(account: @account, user: @user)
    assert_equal 0, FieldItems.recording_json(recording)[:unnamed_speakers]
  end

end
