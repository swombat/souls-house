require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::TranscribeJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = queued_recording(account: @account, user: @user, expected_speakers: 3)
  end

  test "a queued recording is claimed and sent with its attempt and speaker count" do
    client = FakeScribe.new(submit: ElevenLabsScribe::Submission.new(request_id: "req_9", transcription_id: "tr_9"))
    FieldRecordings::TranscribeJob.perform_now(@recording.id, client:, configured: true)

    @recording.reload
    assert @recording.transcribing?
    assert_equal 1, @recording.dispatch_count
    dispatch = @recording.current_dispatch
    assert_equal "in_flight", dispatch.outcome
    assert_equal [ "req_9", "tr_9" ], [ dispatch.request_id, dispatch.transcription_id ]
    sent = client.submissions.first
    assert_equal dispatch.attempt_token, sent[:metadata][:attempt]
    assert_equal 3, sent[:num_speakers]
    assert sent[:file], "local disk storage sends the bytes"
  end

  test "the account glossary goes to Scribe as keyterms" do
    TranscriptionGlossary.new(@account).add!("Lume", by: @user)
    client = FakeScribe.new(submit: ElevenLabsScribe::Submission.new(request_id: "req_9", transcription_id: "tr_9"))
    FieldRecordings::TranscribeJob.perform_now(@recording.id, client:, configured: true)

    assert_includes client.submissions.first[:keyterms], "Lume"
  end

  test "a recording that isn't queued is not sent" do
    @recording.discard_and_settle!
    client = FakeScribe.new
    FieldRecordings::TranscribeJob.perform_now(@recording.id, client:, configured: true)
    assert_empty client.submissions
  end

  test "a refused request fails the recording and gives the allowance back" do
    client = FakeScribe.new(submit: ElevenLabsScribe::PermanentError.new("Scribe returned 422: too long"))
    FieldRecordings::TranscribeJob.perform_now(@recording.id, client:, configured: true)

    @recording.reload
    assert @recording.failed?
    assert_nil @recording.attempt_token
    assert_match "too long", @recording.failure_reason
    assert_equal "released", @recording.reservation.state
  end

  test "a transient error requeues with backoff, and the third failure is final" do
    client = FakeScribe.new(submit: ElevenLabsScribe::TransientError.new("Scribe returned 503"))

    assert_enqueued_with(job: FieldRecordings::TranscribeJob) do
      FieldRecordings::TranscribeJob.perform_now(@recording.id, client:, configured: true)
    end
    assert @recording.reload.queued?

    FieldRecordings::TranscribeJob.perform_now(@recording.id, client:, configured: true)
    FieldRecordings::TranscribeJob.perform_now(@recording.id, client:, configured: true)
    @recording.reload
    assert @recording.failed?
    assert_equal 3, @recording.dispatch_count
    assert_equal "released", @recording.reservation.state
    assert_equal 3, client.submissions.size
  end

  test "a late response for an attempt that's no longer current changes nothing on the recording" do
    dispatch = @recording.claim_dispatch!
    @recording.attempt_failed!(dispatch, "gave up", permanent: false) # the sweep requeued it
    newer = @recording.claim_dispatch!

    @recording.record_submission!(dispatch, ElevenLabsScribe::Submission.new(request_id: "late", transcription_id: "tr_late"))
    assert_equal "tr_late", dispatch.reload.transcription_id, "the stale dispatch still learns its id for cleanup"
    assert_equal newer.attempt_token, @recording.reload.attempt_token
    assert_equal :stale, @recording.attempt_failed!(dispatch, "late error", permanent: true)
    assert @recording.reload.transcribing?
  end

  test "nothing is sent and no attempt is used while Scribe isn't fully configured" do
    client = FakeScribe.new(submit: RuntimeError.new("must not be contacted"))
    %i[api_key webhook_id webhook_secret].each do |missing|
      settings = { api_key: "k", webhook_id: "w", webhook_secret: "s" }.merge(missing => nil)
      ElevenLabsScribe.stub(:api_key, settings[:api_key]) do
        ElevenLabsScribe.stub(:webhook_id, settings[:webhook_id]) do
          ElevenLabsScribe.stub(:webhook_secret, settings[:webhook_secret]) do
            assert_not ElevenLabsScribe.configured?, "#{missing} missing"
            FieldRecordings::TranscribeJob.perform_now(@recording.id, client:)
          end
        end
      end
    end

    @recording.reload
    assert @recording.queued?
    assert_equal 0, @recording.dispatch_count
    assert_empty @recording.dispatches
  end

  test "the account's dispatch exposure bounds retries across recordings, refunds or not" do
    @account.update!(recording_ms_weekly_limit: 90_000) # exposure ceiling: 180 s of audio sent per week
    client = FakeScribe.new(submit: ElevenLabsScribe::PermanentError.new("Scribe refused the request (422)"))

    FieldRecordings::TranscribeJob.perform_now(@recording.id, client:, configured: true)   # 60 s sent, failed, refunded
    again = @recording.reload.retry!(by: @user)
    again.admit!(60_000)
    FieldRecordings::TranscribeJob.perform_now(again.id, client:, configured: true)        # 120 s sent, failed, refunded
    third = queued_recording(account: @account, user: @user)
    FieldRecordings::TranscribeJob.perform_now(third.id, client:, configured: true)        # would be 180 s: allowed
    fourth = queued_recording(account: @account, user: @user)
    FieldRecordings::TranscribeJob.perform_now(fourth.id, client:, configured: true)       # 240 s: refused

    assert_equal 3, client.submissions.size
    fourth.reload
    assert fourth.failed?
    assert_equal FieldRecordingDispatch::EXPOSURE_MESSAGE, fourth.failure_reason
    assert_equal "released", fourth.reservation.state
    assert_empty fourth.dispatches
  end

end
