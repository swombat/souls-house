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

  # The job uses the real client; the voice service and the cut are faked.
  def with_voice_service(vector: voice_vector(@voice.id % 100), &)
    embed = ->(_wav) { FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: vector, profile: "ecapa-test") }
    cut = ->(_recording, _segments, &block) { Tempfile.create([ "s", ".wav" ]) { |file| block.call(file.path) } }
    FieldVoiceprints::VoiceEmbeddings.stub(:embed, embed) { FieldVoiceprints::Sample.stub(:cut, cut, &) }
  end

  test "with a gate shut nothing is embedded" do
    FieldVoiceprints::VoiceEmbeddings.stub(:embed, ->(*) { flunk "nothing is embedded with the gate shut" }) do
      FieldRecordings::IdentifyJob.perform_now(@recording.id)
    end
    assert_nil @recording.speakers.first.reload.recognised_voice_id
  end

  test "with both gates open an untouched speaker is embedded, matched and guessed at" do
    with_recognition(@account) do
      with_voice_service { FieldRecordings::IdentifyJob.perform_now(@recording.id) }
    end
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

  test "a recording discarded before the job runs is not matched" do
    @recording.update_columns(discarded_at: Time.current)
    with_recognition(@account) do
      FieldVoiceprints::VoiceEmbeddings.stub(:embed, ->(*) { flunk "a discarded recording is not embedded" }) do
        FieldRecordings::IdentifyJob.perform_now(@recording.id)
      end
    end
    assert_nil @recording.speakers.first.reload.recognised_voice_id
  end

end
