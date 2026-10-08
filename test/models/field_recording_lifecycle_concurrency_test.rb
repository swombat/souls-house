require "test_helper"
require "support/field_recording_helpers"

# Races from spec §11 that need real threads: a discard racing an accepted
# webhook, and a duplicate webhook racing the first.
class FieldRecordingLifecycleConcurrencyTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Lifecycle race #{SecureRandom.hex(4)}", account_type: "team")
    @user = users(:user_1)
    @recording = queued_recording(account: @account, user: @user)
    @dispatch = @recording.claim_dispatch!
  end

  teardown do
    recordings = FieldRecording.where(account: @account)
    FieldRecordingSpeaker.where(field_recording: recordings).delete_all
    FieldRecordingDispatch.where(field_recording: recordings).delete_all
    FieldRecordingReservation.where(account: @account).delete_all
    recordings.each { |r| r.audio.purge }
    recordings.delete_all
    @account.destroy!
  end

  test "discard racing an accepted transcript: consumed exactly once, whichever wins" do
    results = concurrently(2) do |i|
      recording = FieldRecording.find(@recording.id)
      i.zero? ? recording.discard_and_settle! : recording.accept_transcript!(FieldRecordingDispatch.find(@dispatch.id), scribe_transcription)
    end

    reservation = FieldRecordingReservation.find_by(field_recording_id: @recording.id)
    assert_equal "consumed", reservation.state
    assert_nil reservation.released_at
    if results.include?(:accepted)
      assert @recording.reload.ready?
    else
      assert_equal "superseded", @dispatch.reload.outcome
      assert_nil @recording.reload.transcript_words
    end
    assert @recording.reload.discarded?
  end

  test "two deliveries at once: one acceptance, one consumption" do
    results = concurrently(2) do
      FieldRecording.find(@recording.id).accept_transcript!(FieldRecordingDispatch.find(@dispatch.id), scribe_transcription)
    end

    assert_equal [ :accepted, :duplicate ], results.sort
    assert_equal 2, FieldRecordingSpeaker.where(field_recording_id: @recording.id).count
    assert_equal "consumed", FieldRecordingReservation.find_by(field_recording_id: @recording.id).state
  end

  test "two claims at the account's exposure ceiling: one is sent, one is refused" do
    @account.update!(recording_ms_weekly_limit: 200_000) # allowance 200 s, exposure ceiling 400 s
    earlier = claimed_recording(account: @account, user: @user)
    # 320 s already sent this week: room for one more 45 s attempt, not two.
    FieldRecordingDispatch.create!(field_recording: earlier, account: @account, audio_ms: 320_000 - @dispatch.audio_ms,
      attempt_token: SecureRandom.hex(8))
    a = queued_recording(account: @account, user: @user, duration_ms: 45_000)
    b = queued_recording(account: @account, user: @user, duration_ms: 45_000)

    results = concurrently(2) { |i| FieldRecording.find([ a, b ][i].id).claim_dispatch! }

    assert_equal 1, results.compact.size
    assert_operator FieldRecordingDispatch.exposure_ms(@account), :<=, FieldRecordingDispatch.exposure_limit_ms(@account)
    assert_equal 1, [ a, b ].count { |r| r.reload.failed? }
  end

  private

  def concurrently(count)
    ready, start = Queue.new, Queue.new
    threads = count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield i
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    threads.map(&:value)
  end

end
