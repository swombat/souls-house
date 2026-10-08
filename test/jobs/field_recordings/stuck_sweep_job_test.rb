require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::StuckSweepJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = queued_recording(account: @account, user: @user)
    @dispatch = @recording.claim_dispatch!
    @dispatch.update_columns(created_at: 25.minutes.ago)
  end

  test "a recording waiting too long with no id is requeued and sent again" do
    assert_enqueued_with(job: FieldRecordings::TranscribeJob) do
      FieldRecordings::StuckSweepJob.perform_now(client: FakeScribe.new)
    end
    assert @recording.reload.queued?
    assert_equal "failed", @dispatch.reload.outcome
  end

  test "with the id known, the transcript is fetched and accepted like a webhook" do
    @dispatch.learn_ids!(transcription_id: "tr_1")
    client = FakeScribe.new(fetch: scribe_transcription)

    assert_enqueued_with(job: FieldRecordings::DeleteVendorTranscriptJob) do
      FieldRecordings::StuckSweepJob.perform_now(client:)
    end
    assert @recording.reload.ready?
    assert_equal "consumed", @recording.reservation.state
  end

  test "a recording not yet overdue is left alone" do
    @dispatch.update_columns(created_at: 5.minutes.ago)
    FieldRecordings::StuckSweepJob.perform_now(client: FakeScribe.new)
    assert @recording.reload.transcribing?
  end

  test "the third abandoned attempt fails the recording and releases the allowance" do
    @recording.update_columns(dispatch_count: FieldRecording::MAX_DISPATCHES)
    FieldRecordings::StuckSweepJob.perform_now(client: FakeScribe.new)

    @recording.reload
    assert @recording.failed?
    assert_equal "released", @recording.reservation.state
  end

  test "stranded pending reservations are released" do
    stranded = queued_recording(account: @account, user: @user)
    stranded.update_columns(status: "failed")
    FieldRecordings::StuckSweepJob.perform_now(client: FakeScribe.new)
    assert_equal "released", stranded.reservation.reload.state
  end

  test "a pending reservation stranded on a discarded recording settles by the discard rule" do
    never_sent = queued_recording(account: @account, user: @user)
    never_sent.update_columns(discarded_at: Time.current)
    sent = queued_recording(account: @account, user: @user)
    sent.update_columns(discarded_at: Time.current, dispatch_count: 1)

    FieldRecordings::StuckSweepJob.perform_now(client: FakeScribe.new)
    assert_equal "released", never_sent.reservation.reload.state
    assert_equal "consumed", sent.reservation.reload.state
  end

  test "queued recordings with no live job are sent again" do
    orphan = queued_recording(account: @account, user: @user)
    orphan.update_columns(updated_at: 45.minutes.ago)
    ElevenLabsScribe.stub(:configured?, true) do
      assert_enqueued_with(job: FieldRecordings::TranscribeJob, args: [ orphan.id ]) do
        FieldRecordings::StuckSweepJob.perform_now(client: FakeScribe.new)
      end
    end
  end

  test "queued recordings aren't re-sent while Scribe isn't configured" do
    @dispatch.update_columns(created_at: 1.minute.ago) # keep the in-flight one out of this
    orphan = queued_recording(account: @account, user: @user)
    orphan.update_columns(updated_at: 45.minutes.ago)
    ElevenLabsScribe.stub(:configured?, false) do
      FieldRecordings::StuckSweepJob.perform_now(client: FakeScribe.new)
    end
    assert_no_enqueued_jobs(only: FieldRecordings::TranscribeJob)
  end

end
