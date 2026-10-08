require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @account.update!(recording_ms_weekly_limit: 2.hours.in_milliseconds)
  end

  def recording(**attributes) = claimed_recording(account: @account, user: @user, **attributes)

  test "a recording starts probing and takes its title from the file" do
    r = recording
    assert r.probing?
    assert_equal "test_audio.webm", r.title
    assert_equal "human", r.uploader_kind
  end

  test "expected speakers is bounded by what the transcriber accepts" do
    r = recording
    r.expected_speakers = 33
    assert_not r.valid?
    r.expected_speakers = 0
    assert_not r.valid?
    r.expected_speakers = 3
    assert r.valid?
  end

  test "admission reserves allowance and queues when it fits" do
    r = recording
    assert_equal :admitted, r.admit!(1.hour.in_milliseconds)
    assert r.reload.queued?
    assert_equal 1.hour.in_milliseconds, r.duration_ms
    assert_equal "pending", r.reservation.state
  end

  test "admission refuses when the allowance is used, and reserves nothing" do
    reserve!(recording, 90.minutes.in_milliseconds, state: "consumed", consumed_at: 1.day.ago)
    r = recording

    assert_equal :rejected, r.admit!(1.hour.in_milliseconds)
    assert r.reload.rejected?
    assert_nil r.reservation
    assert_match "You have 30 m left this week", r.failure_reason
  end

  test "a recording discarded while probing gets no reservation" do
    r = recording
    r.discard_and_settle!

    assert_equal :skipped, FieldRecording.find(r.id).admit!(60_000)
    assert_nil r.reload.reservation
  end

  test "admission is idempotent" do
    r = recording
    assert_equal :admitted, r.admit!(60_000)
    assert_equal :skipped, FieldRecording.find(r.id).admit!(60_000)
    assert_equal 1, FieldRecordingReservation.where(field_recording: r).count
  end

  test "discarding before anything was sent releases the allowance and clears the attempt" do
    r = recording
    r.admit!(60_000)
    r.update_columns(attempt_token: "abc")

    assert r.discard_and_settle!
    r.reload
    assert r.discarded?
    assert_nil r.attempt_token
    assert_equal "released", r.reservation.state
    assert_equal "discarded", r.reservation.release_reason
    assert_not r.discard_and_settle!
  end

  test "discarding after a dispatch went out consumes the allowance: the vendor work is paid for" do
    r = recording
    r.admit!(60_000)
    r.update_columns(status: "transcribing", attempt_token: "abc", dispatch_count: 1)

    assert r.discard_and_settle!
    reservation = r.reload.reservation
    assert_equal "consumed", reservation.state
    assert reservation.consumed_at
    assert_nil r.attempt_token
  end

  test "discarding after consumption leaves it consumed" do
    r = recording
    r.admit!(60_000)
    r.reservation.consume!

    r.discard_and_settle!
    assert_equal "consumed", r.reload.reservation.state
  end

  test "discarding keeps the row and the bytes" do
    r = recording
    blob = r.audio.blob
    r.discard_and_settle!
    assert FieldRecording.exists?(r.id)
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_not_includes @account.field_recordings.kept, r
  end

  test "a failed recording can be tried again from the same blob" do
    r = recording(expected_speakers: 2, note: "the long call")
    r.update_columns(status: "failed")

    again = r.retry!(by: @user)
    assert again.probing?
    assert_equal r.audio.blob, again.audio.blob
    assert_equal r, again.retried_from
    assert_equal 2, again.expected_speakers
    assert_equal "the long call", again.note
  end

  test "only failed or rejected recordings that are kept can be tried again" do
    r = recording
    assert_raises(FieldRecording::NotRetryable) { r.retry!(by: @user) }

    r.update_columns(status: "failed")
    r.discard_and_settle!
    assert_raises(FieldRecording::NotRetryable) { FieldRecording.find(r.id).retry!(by: @user) }
  end

  test "destroying an account with an original and its retry works whichever goes first" do
    account = Account.create!(name: "Leaving", account_type: "team")
    original = claimed_recording(account:, user: @user)
    original.update_columns(status: "failed")
    again = original.retry!(by: @user)

    assert_nothing_raised { account.destroy! }
    assert_not FieldRecording.exists?(original.id)
    assert_not FieldRecording.exists?(again.id)
  end

  test "destroying the original leaves the retry with no back-reference" do
    original = recording
    original.update_columns(status: "failed")
    again = original.retry!(by: @user)

    original.destroy!
    assert_nil again.reload.retried_from_id
  end

  test "a rejected recording whose audio was swept keeps an editable title, but can't be retried" do
    r = recording
    r.update_columns(status: "rejected", updated_at: 25.hours.ago)
    FieldRecordings::OrphanSweepJob.perform_now
    r.reload
    assert_not r.audio.attached?

    assert r.update(title: "Renamed after the sweep", note: "still here")
    assert_raises(FieldRecording::NotRetryable) { r.retry!(by: @user) }
  end

end
