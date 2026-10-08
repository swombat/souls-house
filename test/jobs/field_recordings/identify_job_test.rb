require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::IdentifyJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @voice = @account.field_voices.create!(name: "Tomás")
    store_print!(@voice)
  end

  test "with a gate shut nothing is sent" do
    client = FakePyannote.new
    FieldRecordings::IdentifyJob.perform_now(@recording.id, client:)
    assert_empty client.identify_calls
  end

  test "with both gates open it's sent, polled, and applied" do
    client = FakePyannote.new
    with_recognition(@account) do
      assert_enqueued_with(job: FieldRecordings::CollectIdentificationJob) do
        FieldRecordings::IdentifyJob.perform_now(@recording.id, client:)
      end
    end
    identification = FieldRecordingIdentification.last
    label = client.identify_calls.first[:voiceprints].first[:label]
    finished = FakePyannote.new(jobs: { "id_job" => { "status" => "succeeded", "output" => {
      "identification" => [ { "start" => 0.0, "end" => 23.0, "match" => label, "diarizationSpeaker" => "S" } ]
    } } })

    with_recognition(@account) { FieldRecordings::CollectIdentificationJob.perform_now(identification.id, client: finished) }
    assert_equal "done", identification.reload.status
    assert_equal @voice, @recording.speakers.first.reload.recognised_voice
  end

  test "an accepted transcript queues identify only when recognition is on" do
    fresh = queued_recording(account: @account, user: @user)
    dispatch = fresh.claim_dispatch!
    FieldRecording::TranscriptReceiver.receive!(dispatch, scribe_transcription)
    assert_no_enqueued_jobs(only: FieldRecordings::IdentifyJob)

    other = queued_recording(account: @account, user: @user)
    with_recognition(@account) do
      assert_enqueued_with(job: FieldRecordings::IdentifyJob, args: [ other.id ]) do
        FieldRecording::TranscriptReceiver.receive!(other.claim_dispatch!, scribe_transcription)
      end
    end
  end

end
