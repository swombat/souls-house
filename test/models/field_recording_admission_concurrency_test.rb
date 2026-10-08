require "test_helper"
require "support/field_recording_helpers"

# Two probes finishing together must not both fit when only one does (spec §6),
# and a discard racing admission must leave no pending reservation behind.
class FieldRecordingAdmissionConcurrencyTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Recording race #{SecureRandom.hex(4)}", account_type: "team",
      recording_ms_weekly_limit: 90.minutes.in_milliseconds)
    @user = users(:user_1)
    @recordings = 2.times.map { claimed_recording(account: @account, user: @user) }
  end

  teardown do
    FieldRecordingReservation.where(account: @account).delete_all
    @account.field_recordings.each { |r| r.audio.purge }
    FieldRecording.where(account: @account).delete_all
    @account.destroy!
  end

  test "two hour-long recordings can't both fit in ninety minutes" do
    results = concurrently(2) { |i| FieldRecording.find(@recordings[i].id).admit!(1.hour.in_milliseconds) }

    assert_equal [ :admitted, :rejected ], results.sort
    assert_equal 1.hour.in_milliseconds, FieldRecordingReservation.used_ms(@account)
  end

  test "discard racing admission leaves nothing pending" do
    target = @recordings.first
    concurrently(2) do |i|
      i.zero? ? FieldRecording.find(target.id).discard_and_settle! : FieldRecording.find(target.id).admit!(60_000)
    end

    assert_equal 0, FieldRecordingReservation.where(field_recording_id: target.id, state: "pending").count
    assert target.reload.discarded?
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
