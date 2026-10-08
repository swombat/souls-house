require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::OrphanSweepJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  test "unclaimed uploads are purged once their pin has expired, and not before" do
    fresh = pinned_blob(account: @account, user: @user)
    stale = pinned_blob(account: @account, user: @user)
    stale.update_columns(created_at: 7.hours.ago)
    unrelated = ActiveStorage::Blob.create_and_upload!(io: file_fixture("test.txt").open, filename: "x.txt")
    unrelated.update_columns(created_at: 7.hours.ago)

    perform_enqueued_jobs { FieldRecordings::OrphanSweepJob.perform_now }

    assert ActiveStorage::Blob.exists?(fresh.id)
    assert_not ActiveStorage::Blob.exists?(stale.id)
    assert ActiveStorage::Blob.exists?(unrelated.id)
  end

  test "claimed uploads are never purged" do
    recording = claimed_recording(account: @account, user: @user)
    recording.audio.blob.update_columns(created_at: 7.hours.ago)

    perform_enqueued_jobs { FieldRecordings::OrphanSweepJob.perform_now }
    assert recording.reload.audio.attached?
  end

  test "rejected audio goes after a day, unless a retry shares the blob" do
    alone = claimed_recording(account: @account, user: @user)
    alone.update_columns(status: "rejected", updated_at: 25.hours.ago)

    shared = claimed_recording(account: @account, user: @user)
    shared.update_columns(status: "rejected")
    retried = shared.retry!(by: @user)
    shared.update_columns(updated_at: 25.hours.ago)

    perform_enqueued_jobs { FieldRecordings::OrphanSweepJob.perform_now }

    assert_not alone.reload.audio.attached?
    assert_not shared.reload.audio.attached?
    assert retried.reload.audio.attached?
    assert ActiveStorage::Blob.exists?(retried.audio.blob.id)
  end

  test "an upload whose pin has really expired is purged and can no longer be claimed" do
    blob = pinned_blob(account: @account, user: @user)

    travel FieldRecording::Upload::TTL + 1.minute do
      perform_enqueued_jobs { FieldRecordings::OrphanSweepJob.perform_now }
      assert_not ActiveStorage::Blob.exists?(blob.id)
      assert_nil FieldRecording::Upload.claim!(account: @account, user: @user, signed_id: blob.signed_id, attributes: {})
    end
  end

end
