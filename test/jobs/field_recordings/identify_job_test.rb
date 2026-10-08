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


  # Malformed successes Mira and the Sol helper found on 7a19009, through the
  # collector: each finishes (never left dispatched), raises nothing, and
  # makes no guess.
  {
    "a nested confidence array" => ->(label) { { "confidence" => { label => [] } } },
    "a nested confidence hash" => ->(label) { { "confidence" => { label => { "x" => 1 } } } },
    "a boolean confidence" => ->(label) { { "confidence" => { label => true } } },
    "an infinite confidence" => ->(label) { { "confidence" => { label => Float::INFINITY } } },
    "a confidence out of range" => ->(label) { { "confidence" => { label => 1e300 } } },
    "a timestamp that overflows milliseconds" => ->(_label) { { "end" => 1e308 } },
    "a negative timestamp" => ->(_label) { { "start" => -5.0 } }
  }.each do |description, malform|
    test "#{description} finishes safely with no guess" do
      client = FakePyannote.new
      with_recognition(@account) { FieldRecordings::IdentifyJob.perform_now(@recording.id, client:) }
      identification = FieldRecordingIdentification.last
      label = client.identify_calls.first[:voiceprints].first[:label]
      bad = malform.call(label)
      segment = { "start" => 0.0, "end" => 23.0, "match" => label, "diarizationSpeaker" => "S" }.merge(bad.except("confidence"))
      output = { "identification" => [ segment ] }
      output["voiceprints"] = [ { "speaker" => "S", "match" => label, "confidence" => bad["confidence"] } ] if bad["confidence"]
      malformed = FakePyannote.new(jobs: { "id_job" => { "status" => "succeeded", "output" => output } })

      with_recognition(@account) do
        assert_nothing_raised { FieldRecordings::CollectIdentificationJob.perform_now(identification.id, client: malformed) }
      end
      refute_equal "dispatched", identification.reload.status
      assert_nil @recording.speakers.first.reload.recognised_voice_id
    end
  end

  test "a recording discarded before collection ends the identification" do
    client = FakePyannote.new
    with_recognition(@account) { FieldRecordings::IdentifyJob.perform_now(@recording.id, client:) }
    identification = FieldRecordingIdentification.last
    @recording.update_columns(discarded_at: Time.current)
    finished = FakePyannote.new(jobs: { "id_job" => { "status" => "succeeded", "output" => { "identification" => [] } } })

    with_recognition(@account) { FieldRecordings::CollectIdentificationJob.perform_now(identification.id, client: finished) }
    assert_equal "failed", identification.reload.status
  end

end
