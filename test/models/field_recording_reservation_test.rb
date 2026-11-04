require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingReservationTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @account.update!(recording_ms_weekly_limit: 10.hours.in_milliseconds)
  end

  def recording = claimed_recording(account: @account, user: @user)

  test "pending counts at any age, consumed counts for seven days from consumption" do
    now = Time.current
    reserve!(recording, 1.hour.in_milliseconds).update_columns(reserved_at: 30.days.ago)
    reserve!(recording, 2.hours.in_milliseconds, state: "consumed", consumed_at: 6.days.ago)
    reserve!(recording, 4.hours.in_milliseconds, state: "consumed", consumed_at: 8.days.ago)
    reserve!(recording, 8.hours.in_milliseconds, state: "released")

    assert_equal 3.hours.in_milliseconds, FieldRecordingReservation.used_ms(@account, now:)
  end

  test "consume and release each happen once, and release after consume does nothing" do
    reservation = reserve!(recording, 60_000)
    consumed_at = Time.current.change(usec: 0)

    assert reservation.consume!(now: consumed_at)
    assert_not reservation.consume!(now: consumed_at + 1.day)
    assert_not reservation.release!(reason: "discarded")
    assert_equal "consumed", reservation.reload.state
    assert_nil reservation.released_at
    assert_equal consumed_at, reservation.consumed_at
  end

  test "a stale transcription worker cannot consume released allowance or change its release reason" do
    reservation = reserve!(recording, 60_000)
    stale = FieldRecordingReservation.find(reservation.id)
    released_at = Time.current.change(usec: 0)

    assert reservation.release!(reason: "discarded", now: released_at)
    assert_not stale.consume!(now: released_at + 1.minute)
    assert_not stale.release!(reason: "failed", now: released_at + 2.minutes)
    assert_equal "released", stale.state
    assert_equal "discarded", stale.release_reason
    assert_equal released_at, stale.released_at
    assert_nil stale.consumed_at
    assert_equal 0, FieldRecordingReservation.used_ms(@account)
  end

  test "room frees up when enough consumed allowance ages out" do
    now = Time.current
    reserve!(recording, 6.hours.in_milliseconds, state: "consumed", consumed_at: 5.days.ago)
    reserve!(recording, 3.hours.in_milliseconds, state: "consumed", consumed_at: 2.days.ago)

    at = FieldRecordingReservation.room_at(@account, 4.hours.in_milliseconds, now:)
    assert_in_delta (5.days.ago + 7.days).to_f, at.to_f, 1
  end

  test "no estimate when pending work alone leaves too little room" do
    reserve!(recording, 8.hours.in_milliseconds)

    assert_nil FieldRecordingReservation.room_at(@account, 3.hours.in_milliseconds)
    assert_match "No estimate yet", FieldRecordingReservation.over_limit_message(@account, 3.hours.in_milliseconds)
  end

  test "a recording longer than the whole allowance says so" do
    message = FieldRecordingReservation.over_limit_message(@account, 11.hours.in_milliseconds)
    assert_match "longer than this Field's whole weekly allowance", message
  end

  test "one reservation per recording, even outside the lock" do
    target = recording
    reserve!(target, 60_000)
    assert_raises(ActiveRecord::RecordNotUnique) { reserve!(target, 60_000) }
  end

end
