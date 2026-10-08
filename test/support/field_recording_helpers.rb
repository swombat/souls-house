# Shared setup for recording tests: a direct-upload blob pinned to a user and
# account exactly as FieldRecordingUploadsController makes one.
module FieldRecordingHelpers

  def pinned_blob(account:, user:, fixture: "test_audio.webm", content_type: "audio/webm")
    pin = FieldRecording::Upload.pin_for(account:, user:)
    ActiveStorage::Blob.create_and_upload!(
      io: file_fixture(fixture).open, filename: fixture, content_type:,
      metadata: { FieldRecording::Upload::METADATA_KEY => pin }
    )
  end

  def claimed_recording(account:, user:, **attributes)
    FieldRecording::Upload.claim!(
      account:, user:, signed_id: pinned_blob(account:, user:).signed_id, attributes:
    )
  end

  def reserve!(recording, ms, state: "pending", consumed_at: nil)
    FieldRecordingReservation.create!(
      account: recording.account, field_recording: recording, audio_ms: ms,
      state:, consumed_at:, reserved_at: consumed_at || Time.current
    )
  end

end
