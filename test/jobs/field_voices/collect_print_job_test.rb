require "test_helper"
require "support/field_recording_helpers"

class FieldVoices::CollectPrintJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "Tomás")
    @speaker.name_as!(@voice, by: @user)
  end

  def dispatched_enrolment
    with_recognition(@account) do
      FieldVoiceprints::Sample.stub(:cut, ->(_r, _s, &block) { Tempfile.create([ "s", ".wav" ]) { |f| block.call(f.path) } }) do
        enrolment = FieldVoiceprints::Enrolments.start!(@speaker, by: @user)
        FieldVoiceprints::Enrolments.dispatch!(enrolment, client: FakePyannote.new)
      end
    end
  end

  test "a finished print is stored when every check still holds" do
    enrolment = dispatched_enrolment
    client = FakePyannote.new(jobs: { "vp_job" => { "status" => "succeeded", "output" => { "voiceprint" => "PRINT" } } })
    with_recognition(@account) { FieldVoices::CollectPrintJob.perform_now(enrolment.id, client:) }
    assert @voice.reload.remembered?
  end

  test "a job still running is polled again, and polling is bounded" do
    enrolment = dispatched_enrolment
    client = FakePyannote.new(jobs: { "vp_job" => { "status" => "running" } })
    assert_enqueued_with(job: FieldVoices::CollectPrintJob, args: [ enrolment.id ]) do
      FieldVoices::CollectPrintJob.perform_now(enrolment.id, client:)
    end

    enrolment.update_columns(poll_count: FieldVoices::CollectPrintJob::POLL_LIMIT)
    FieldVoices::CollectPrintJob.perform_now(enrolment.id, client:)
    assert_not FieldVoiceEnrolment.exists?(enrolment.id)
    assert_nil @voice.reload.voiceprint
  end

  test "a failed job drops the enrolment and stores nothing" do
    enrolment = dispatched_enrolment
    FieldVoices::CollectPrintJob.perform_now(enrolment.id, client: FakePyannote.new(jobs: { "vp_job" => { "status" => "failed" } }))
    assert_not FieldVoiceEnrolment.exists?(enrolment.id)
    assert_nil @voice.reload.voiceprint
  end

end
