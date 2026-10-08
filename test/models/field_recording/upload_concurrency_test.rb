require "test_helper"
require "support/field_recording_helpers"

# Claims take the blob's row lock (spec §4): two creates racing for one upload,
# or a claim racing the orphan purge, have exactly one winner.
class FieldRecording::UploadConcurrencyTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Upload race #{SecureRandom.hex(4)}", account_type: "team")
    @user = users(:user_1)
  end

  teardown do
    @account.field_recordings.each { |r| r.audio.purge }
    FieldRecording.where(account: @account).delete_all
    @account.destroy!
  end

  test "two claims for one upload: exactly one recording" do
    blob = pinned_blob(account: @account, user: @user)
    results = concurrently(2) do
      FieldRecording::Upload.claim!(account: @account, user: @user, signed_id: blob.signed_id, attributes: { title: "x" })
    end

    assert_equal 1, results.compact.size
    assert_equal 1, ActiveStorage::Attachment.where(blob_id: blob.id).count
  end

  test "a claim racing the orphan purge of a purge-eligible row: either claimed and kept, or purged and unclaimed" do
    blob = pinned_blob(account: @account, user: @user)
    blob.update_columns(created_at: 7.hours.ago)

    results = nil
    perform_enqueued_jobs do
      results = concurrently(2) do |i|
        if i.zero?
          FieldRecordings::OrphanSweepJob.perform_now
          :swept
        else
          # Artificial on purpose: the pin is still valid while the row looks
          # old enough to purge, to force the lock to decide. Real pin expiry is
          # covered in OrphanSweepJobTest.
          FieldRecording::Upload.claim!(account: @account, user: @user, signed_id: blob.signed_id, attributes: { title: "x" })
        end
      end
    end

    claimed = results.find { |r| r.is_a?(FieldRecording) }
    if claimed
      assert ActiveStorage::Blob.exists?(blob.id), "a claimed blob must not be purged"
    else
      assert_not ActiveStorage::Blob.exists?(blob.id)
    end
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
