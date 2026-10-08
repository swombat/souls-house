require "test_helper"
require "support/field_recording_helpers"

class ElevenLabsSttWebhooksControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  SECRET = "whsec_test"

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = queued_recording(account: @account, user: @user)
    @dispatch = @recording.claim_dispatch!
  end

  def deliver(dispatch: @dispatch, transcription: scribe_transcription, secret: SECRET, metadata_as_string: false)
    metadata = { "recording" => dispatch.field_recording.to_param, "attempt" => dispatch.attempt_token }
    body = { type: "speech_to_text_transcription", data: {
      request_id: "req_1", webhook_metadata: metadata_as_string ? metadata.to_json : metadata, transcription:
    } }.to_json
    t = Time.current.to_i
    signature = "t=#{t},v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{t}.#{body}")}"
    ElevenLabsScribe.stub(:webhook_secret, SECRET) do
      post eleven_labs_stt_webhook_path, params: body, headers: { "CONTENT_TYPE" => "application/json", "ElevenLabs-Signature" => signature }
    end
  end

  test "an unsigned or wrongly signed delivery is refused and touches nothing" do
    deliver(secret: "wrong")
    assert_response :unauthorized
    assert @recording.reload.transcribing?
  end

  test "the current attempt's transcript is stored, consumed once and deleted at the vendor" do
    assert_enqueued_with(job: FieldRecordings::DeleteVendorTranscriptJob, args: [ @dispatch.id ]) do
      deliver(metadata_as_string: true)
    end
    assert_response :ok

    @recording.reload
    assert @recording.ready?
    assert_nil @recording.attempt_token
    assert_equal %w[speaker_0 speaker_1], @recording.speakers.map(&:label)
    assert_equal "[00:00] Speaker 1: hello\n[00:02] Speaker 2: there", @recording.transcript_text
    assert_equal "consumed", @recording.reservation.state
    assert_equal "succeeded", @dispatch.reload.outcome
    assert_equal "tr_1", @dispatch.transcription_id
  end

  test "a duplicate delivery changes nothing and never downgrades the success" do
    deliver
    consumed_at = @recording.reload.reservation.consumed_at
    deliver

    assert_equal "succeeded", @dispatch.reload.outcome
    assert_equal consumed_at, @recording.reload.reservation.consumed_at
    assert_equal 2, @recording.speakers.count
  end

  test "a stale attempt's transcript is ignored but still deleted at the vendor" do
    @recording.attempt_failed!(@dispatch, "gave up", permanent: false)
    @recording.claim_dispatch!

    assert_enqueued_with(job: FieldRecordings::DeleteVendorTranscriptJob, args: [ @dispatch.id ]) do
      deliver
    end
    assert_equal "superseded", @dispatch.reload.outcome
    assert @recording.reload.transcribing?
    assert_nil @recording.transcript_words
  end

  test "a transcript for a recording discarded mid-transcription is ignored and still deleted" do
    @recording.discard_and_settle!
    consumed_at = @recording.reload.reservation.consumed_at
    assert_equal "consumed", @recording.reservation.state, "the dispatch went out, so the allowance stays spent"

    assert_enqueued_with(job: FieldRecordings::DeleteVendorTranscriptJob) { deliver }

    assert_equal "superseded", @dispatch.reload.outcome
    assert_equal consumed_at, @recording.reload.reservation.consumed_at
    assert_nil @recording.transcript_words
  end

  test "a webhook before the POST response: the id is kept when the response arrives with none" do
    deliver
    @recording.record_submission!(@dispatch, ElevenLabsScribe::Submission.new(request_id: nil, transcription_id: nil))
    assert_equal "tr_1", @dispatch.reload.transcription_id
    assert_equal "req_1", @dispatch.request_id
  end

  test "unknown attempts and other event types are acknowledged and ignored" do
    other = @dispatch.dup.tap { |d| d.attempt_token = "nope" }
    deliver(dispatch: other)
    assert_response :ok
    assert @recording.reload.transcribing?
  end

end
