require "test_helper"

class TranscriptionChargeTest < ActiveSupport::TestCase

  setup do
    @account = Account.create!(name: "Limited #{SecureRandom.hex(3)}", account_type: "team", granted_plan: "partners",
      transcription_ms_limit_override: 10.minutes.in_milliseconds)
    @account.memberships.create!(user: users(:regular_user), role: "owner", confirmed_at: Time.current)
    @path = file_fixture("test_audio.webm").to_s
  end

  def admit(key:, ms:, now: Time.current)
    TranscriptionCharge.stub(:measure, [ ms, false ]) do
      TranscriptionCharge.admit!(account: @account, source: "voice_note", key:, path: @path, byte_size: 1, now:)
    end
  end

  test "audio is counted against the allowance recordings use" do
    admit(key: 1, ms: 4.minutes.in_milliseconds)

    assert_equal 4.minutes.in_milliseconds, FieldRecordingReservation.used_ms(@account)
  end

  test "audio that doesn't fit is refused and nothing is counted" do
    admit(key: 1, ms: 8.minutes.in_milliseconds)

    error = assert_raises(TranscriptionCharge::Refused) { admit(key: 2, ms: 3.minutes.in_milliseconds) }
    assert_match "Transcription has stopped for now", error.message
    assert_match "2 m", error.message
    assert_equal 1, TranscriptionCharge.where(account: @account).count
  end

  test "sending the same audio again is not counted twice, but each send counts toward the vendor ceiling" do
    admit(key: 1, ms: 6.minutes.in_milliseconds)
    admit(key: 1, ms: 6.minutes.in_milliseconds)

    assert_equal 6.minutes.in_milliseconds, FieldRecordingReservation.used_ms(@account)
    assert_equal 12.minutes.in_milliseconds, FieldRecordingDispatch.exposure_ms(@account)
  end

  test "retries stop at the vendor ceiling of twice the allowance" do
    3.times { admit(key: 1, ms: 6.minutes.in_milliseconds) }

    error = assert_raises(TranscriptionCharge::Refused) { admit(key: 1, ms: 6.minutes.in_milliseconds) }
    assert_equal FieldRecordingDispatch::EXPOSURE_MESSAGE, error.message
  end

  test "audio older than 30 days no longer counts" do
    admit(key: 1, ms: 8.minutes.in_milliseconds, now: 31.days.ago)

    assert_equal 0, FieldRecordingReservation.used_ms(@account)
    assert_nothing_raised { admit(key: 2, ms: 8.minutes.in_milliseconds) }
  end

  test "the refusal says when room returns" do
    admit(key: 1, ms: 8.minutes.in_milliseconds, now: 10.days.ago)

    error = assert_raises(TranscriptionCharge::Refused) { admit(key: 2, ms: 5.minutes.in_milliseconds) }
    assert_match "enough for this by about #{20.days.from_now.strftime('%a %-d %b')}", error.message
  end

  test "an unreadable file is charged by its size, erring long" do
    Tempfile.create("noise") do |file|
      file.write("x" * 30_000)
      file.flush
      ms, estimated = TranscriptionCharge.measure(file.path, byte_size: 30_000)

      assert estimated
      assert_equal 10_000, ms
    end
  end

end
