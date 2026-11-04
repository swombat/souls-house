require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::PlaybackJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  test "an MP3 original gets an AAC copy the player can seek" do
    recording = mp3_recording
    FieldRecordings::PlaybackJob.perform_now(recording.id)

    recording.reload
    assert recording.playback.attached?
    assert_equal [ "test_playback.m4a", "audio/mp4" ], [ recording.playback.filename.to_s, recording.playback.content_type ]
    recording.playback.blob.open do |file|
      assert_equal "aac", FieldRecording::Playback.codec(file.path)
      assert_in_delta 1.0, FieldRecording::Probe.duration_ms(file.path) / 1000.0, 0.2
    end
  end

  test "a format the browser seeks well is played as it is" do
    recording = claimed_recording(account: @account, user: @user) # Opus in WebM
    FieldRecordings::PlaybackJob.perform_now(recording.id)
    assert_not recording.reload.playback.attached?
  end

  test "a copy already made is kept, and a discarded recording gets none" do
    recording = mp3_recording
    FieldRecordings::PlaybackJob.perform_now(recording.id)
    first = recording.reload.playback.blob
    FieldRecordings::PlaybackJob.perform_now(recording.id)
    assert_equal first, recording.reload.playback.blob

    discarded = mp3_recording
    discarded.discard_and_settle!
    FieldRecordings::PlaybackJob.perform_now(discarded.id)
    assert_not discarded.reload.playback.attached?
  end

  test "a file ffmpeg can't read leaves the recording without a copy" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: file_fixture("test.txt").open, filename: "fake.mp3", content_type: "audio/mpeg",
      metadata: { FieldRecording::Upload::METADATA_KEY => FieldRecording::Upload.pin_for(account: @account, user: @user) }
    )
    recording = FieldRecording::Upload.claim!(account: @account, user: @user, signed_id: blob.signed_id, attributes: {})
    FieldRecordings::PlaybackJob.perform_now(recording.id)
    assert_not recording.reload.playback.attached?
  end

  private

  def mp3_recording
    FieldRecording::Upload.claim!(
      account: @account, user: @user, attributes: {},
      signed_id: pinned_blob(account: @account, user: @user, fixture: "test_playback.mp3", content_type: "audio/mpeg").signed_id
    )
  end

end
