require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::DeleteVendorTranscriptJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  setup do
    @recording = queued_recording(account: accounts(:personal_account), user: users(:user_1))
    @dispatch = @recording.claim_dispatch!
  end

  test "a known transcript is deleted and the deletion recorded" do
    @dispatch.learn_ids!(transcription_id: "tr_1")
    client = FakeScribe.new
    FieldRecordings::DeleteVendorTranscriptJob.perform_now(@dispatch.id, client:)

    assert_equal [ "tr_1" ], client.deleted
    assert @dispatch.reload.vendor_deleted_at
  end

  test "with no id the limitation is recorded, and learning the id later queues the deletion again" do
    FieldRecordings::DeleteVendorTranscriptJob.perform_now(@dispatch.id, client: FakeScribe.new)
    assert_equal FieldRecordingDispatch::NO_ID, @dispatch.reload.vendor_delete_error

    assert_enqueued_with(job: FieldRecordings::DeleteVendorTranscriptJob, args: [ @dispatch.id ]) do
      @dispatch.learn_ids!(transcription_id: "tr_late")
    end
    assert_nil @dispatch.reload.vendor_delete_error
  end

  test "a later null never erases a known id" do
    @dispatch.learn_ids!(request_id: "req_1", transcription_id: "tr_1")
    @dispatch.learn_ids!(request_id: nil, transcription_id: nil)
    @dispatch.learn_ids!(transcription_id: "tr_other")
    assert_equal [ "req_1", "tr_1" ], [ @dispatch.reload.request_id, @dispatch.transcription_id ]
  end

  test "a refused deletion is recorded without content" do
    @dispatch.learn_ids!(transcription_id: "tr_1")
    client = FakeScribe.new(delete_error: ElevenLabsScribe::PermanentError.new("Scribe returned 403: forbidden"))
    FieldRecordings::DeleteVendorTranscriptJob.perform_now(@dispatch.id, client:)

    assert_nil @dispatch.reload.vendor_deleted_at
    assert_match "403", @dispatch.vendor_delete_error
  end

  test "abandoned attempt, late id, no webhook: cleanup starts, waits through early 404s, then deletes" do
    @recording.attempt_failed!(@dispatch, "no result", permanent: false) # the sweep gave up; no id yet

    assert_enqueued_with(job: FieldRecordings::DeleteVendorTranscriptJob, args: [ @dispatch.id ]) do
      @recording.record_submission!(@dispatch, ElevenLabsScribe::Submission.new(request_id: "req_late", transcription_id: "tr_late"))
    end

    client = FakeScribe.new(delete_results: [ :not_found ])
    assert_enqueued_with(job: FieldRecordings::DeleteVendorTranscriptJob, args: [ @dispatch.id ]) do
      FieldRecordings::DeleteVendorTranscriptJob.perform_now(@dispatch.id, client:)
    end
    @dispatch.reload
    assert_nil @dispatch.vendor_deleted_at, "an early 404 is not proof of deletion"
    assert_equal 1, @dispatch.vendor_delete_attempts

    FieldRecordings::DeleteVendorTranscriptJob.perform_now(@dispatch.id, client:) # the transcript exists now
    assert @dispatch.reload.vendor_deleted_at
  end

  test "repeated 404s for an attempt we never accepted stop after a bounded number of tries, visibly" do
    @recording.attempt_failed!(@dispatch, "no result", permanent: false)
    @dispatch.learn_ids!(transcription_id: "tr_ghost")
    attempts = FieldRecordings::DeleteVendorTranscriptJob::NOT_FOUND_WAITS.size + 1
    client = FakeScribe.new(delete_results: [ :not_found ] * attempts)

    attempts.times { FieldRecordings::DeleteVendorTranscriptJob.perform_now(@dispatch.id, client:) }

    @dispatch.reload
    assert_nil @dispatch.vendor_deleted_at
    assert_equal FieldRecordings::DeleteVendorTranscriptJob::NOT_FOUND, @dispatch.vendor_delete_error
    assert_equal attempts, client.deleted.size
  end

  test "a 404 for a transcript we accepted means it's already gone" do
    @recording.accept_transcript!(@dispatch, scribe_transcription(transcription_id: "tr_1"))
    FieldRecordings::DeleteVendorTranscriptJob.perform_now(@dispatch.id, client: FakeScribe.new(delete_results: [ :not_found ]))
    assert @dispatch.reload.vendor_deleted_at
  end

  test "abandoning an attempt whose id is already known queues its cleanup" do
    @dispatch.learn_ids!(transcription_id: "tr_known")
    assert_enqueued_with(job: FieldRecordings::DeleteVendorTranscriptJob, args: [ @dispatch.id ]) do
      @recording.attempt_failed!(@dispatch, "no result", permanent: false)
    end
  end

end
