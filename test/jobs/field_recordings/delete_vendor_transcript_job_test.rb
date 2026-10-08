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

end
