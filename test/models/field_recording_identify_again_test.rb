require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingIdentifyAgainTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @previous_suggestions = ENV["SOULSHOUSE_FIELD_SUGGESTIONS"]
    ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] = nil
  end

  teardown { ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] = @previous_suggestions }

  test "with both passes' gates shut nothing is queued" do
    assert_no_enqueued_jobs do
      assert_equal [], FieldRecording::IdentifyAgain.queue!(@recording)
    end
  end

  test "with recognition on, the identify job is queued again" do
    with_recognition(@account) do
      assert_enqueued_with(job: FieldRecordings::IdentifyJob, args: [ @recording.id ]) do
        assert_equal [ :voices ], FieldRecording::IdentifyAgain.queue!(@recording)
      end
    end
  end

  test "names from what's said: a finished or failed call is reopened, a claimed one is left alone" do
    ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] = "on"
    %w[done failed].each do |state|
      @recording.update_columns(suggestions_state: state)
      assert_enqueued_with(job: FieldRecordings::SuggestSpeakersJob, args: [ @recording.id ]) do
        assert_equal [ :names ], FieldRecording::IdentifyAgain.queue!(@recording)
      end
      assert_nil @recording.reload.suggestions_state
    end

    @recording.update_columns(suggestions_state: "claimed")
    assert_no_enqueued_jobs(only: FieldRecordings::SuggestSpeakersJob) do
      assert_equal [], FieldRecording::IdentifyAgain.queue!(@recording)
    end
    assert_equal "claimed", @recording.reload.suggestions_state
  end

  test "a supplied transcript or an unfinished recording gets neither pass" do
    ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] = "on"
    queued = queued_recording(account: @account, user: @user)
    with_recognition(@account) do
      assert_equal [], FieldRecording::IdentifyAgain.queue!(queued)
      @recording.update_columns(transcript_source: "supplied")
      assert_equal [], FieldRecording::IdentifyAgain.queue!(@recording.reload)
    end
  end

  # Matching is in the house and writes under the recording lock, so two
  # presses just match twice: one guess, and the kept probe means the audio
  # is embedded once.
  test "two presses before any worker runs match twice and make one guess" do
    voice = @account.field_voices.create!(name: "Tomás")
    store_print!(voice)
    embedded = 0
    embed = ->(_wav) do
      embedded += 1
      FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: voice_vector(voice.id % 100), profile: "ecapa-test")
    end
    cut = ->(_recording, _segments, &block) { Tempfile.create([ "s", ".wav" ]) { |file| block.call(file.path) } }
    with_recognition(@account) do
      2.times { assert_equal [ :voices ], FieldRecording::IdentifyAgain.queue!(@recording) }
      jobs = enqueued_jobs.select { |job| job["job_class"] == "FieldRecordings::IdentifyJob" }
      assert_equal 2, jobs.size, "both presses queue"
      FieldVoiceprints::VoiceEmbeddings.stub(:embed, embed) do
        FieldVoiceprints::Sample.stub(:cut, cut) { jobs.each { FieldRecordings::IdentifyJob.perform_now(@recording.id) } }
      end
    end
    assert_equal 1, embedded
    assert_equal [ voice.id ], @recording.speakers.reload.filter_map(&:recognised_voice_id)
  end

end
