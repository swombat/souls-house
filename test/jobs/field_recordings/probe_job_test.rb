require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::ProbeJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  test "a readable recording is measured and admitted" do
    recording = claimed_recording(account: @account, user: @user)
    FieldRecordings::ProbeJob.perform_now(recording.id)

    recording.reload
    assert recording.queued?
    assert recording.duration_ms.positive?
    assert_equal recording.duration_ms, recording.reservation.audio_ms
  end

  test "a file with no audio is rejected without using allowance" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: file_fixture("test.txt").open, filename: "fake.mp3", content_type: "audio/mpeg",
      metadata: { FieldRecording::Upload::METADATA_KEY => FieldRecording::Upload.pin_for(account: @account, user: @user) }
    )
    recording = FieldRecording::Upload.claim!(account: @account, user: @user, signed_id: blob.signed_id, attributes: {})
    FieldRecordings::ProbeJob.perform_now(recording.id)

    recording.reload
    assert recording.rejected?
    assert_equal FieldRecordings::ProbeJob::UNREADABLE, recording.failure_reason
    assert_nil recording.reservation
  end

  test "a discarded or already-probed recording is left alone" do
    recording = claimed_recording(account: @account, user: @user)
    recording.discard_and_settle!
    FieldRecordings::ProbeJob.perform_now(recording.id)
    assert recording.reload.probing?
    assert_nil recording.reservation
  end

end
