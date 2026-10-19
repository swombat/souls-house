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

  test "an identify job still out isn't doubled" do
    FieldRecordingIdentification.create!(field_recording: @recording, vendor_job_id: "out", snapshot: {}, speaker_decisions: {})
    with_recognition(@account) do
      assert_no_enqueued_jobs(only: FieldRecordings::IdentifyJob) do
        assert_equal [], FieldRecording::IdentifyAgain.queue!(@recording)
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


  test "two presses before any worker runs make one paid identify call" do
    voice = @account.field_voices.create!(name: "Tomás")
    store_print!(voice)
    client = FakePyannote.new
    with_recognition(@account) do
      2.times { assert_equal [ :voices ], FieldRecording::IdentifyAgain.queue!(@recording) }
      jobs = enqueued_jobs.select { |job| job["job_class"] == "FieldRecordings::IdentifyJob" }
      assert_equal 2, jobs.size, "both presses queue: the claim is at dispatch"
      jobs.each { FieldRecordings::IdentifyJob.perform_now(@recording.id, client:) }
    end
    assert_equal 1, client.identify_calls.size
    assert_equal 1, @recording.identifications.where(status: "dispatched").count
  end

  test "a worker that finds an identify already out sends nothing" do
    voice = @account.field_voices.create!(name: "Tomás")
    store_print!(voice)
    FieldRecordingIdentification.create!(field_recording: @recording, vendor_job_id: "out", snapshot: {}, speaker_decisions: {})
    client = FakePyannote.new
    with_recognition(@account) { FieldRecordings::IdentifyJob.perform_now(@recording.id, client:) }
    assert_empty client.identify_calls
  end

  test "once the earlier identify has finished, another can be sent" do
    voice = @account.field_voices.create!(name: "Tomás")
    store_print!(voice)
    FieldRecordingIdentification.create!(field_recording: @recording, vendor_job_id: "old", snapshot: {}, speaker_decisions: {}, status: "done")
    client = FakePyannote.new
    with_recognition(@account) { FieldRecordings::IdentifyJob.perform_now(@recording.id, client:) }
    assert_equal 1, client.identify_calls.size
  end


  test "a dispatch whose collector never ran stops holding up another pass after an hour" do
    voice = @account.field_voices.create!(name: "Tomás")
    store_print!(voice)
    FieldRecordingIdentification.create!(field_recording: @recording, vendor_job_id: "orphan", snapshot: {},
      speaker_decisions: {}, created_at: 2.hours.ago)
    client = FakePyannote.new
    with_recognition(@account) { FieldRecordings::IdentifyJob.perform_now(@recording.id, client:) }
    assert_equal 1, client.identify_calls.size
  end

end
