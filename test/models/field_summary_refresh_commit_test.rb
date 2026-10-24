require "test_helper"
require "support/field_recording_helpers"

class FieldSummaryRefreshCommitTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Summary commit #{SecureRandom.hex(4)}", account_type: "team")
    @user = users(:user_1)
    @recording = ready_recording(account: @account, user: @user)
    clear_enqueued_jobs
  end

  teardown do
    @recording.audio.purge
    @account.destroy!
  end

  def correct
    @recording.correct_line_number!(1, text: "good morning", was: "hello",
      revision: @recording.transcript_revision)
  end

  test "human correction is enqueued only after the outer transaction commits" do
    freeze_time do
      assert_enqueued_with(job: FieldItems::RefreshSummaryJob, args: [ @recording ], at: 30.minutes.from_now) do
        FieldRecording.transaction do
          correct
          assert_no_enqueued_jobs(only: FieldItems::RefreshSummaryJob)
          assert @recording.summary_refresh_due_at
        end
      end
    end
  end

  test "outer rollback does not enqueue or preserve human authorization" do
    before = @recording.transcript_text
    assert_no_enqueued_jobs(only: FieldItems::RefreshSummaryJob) do
      FieldRecording.transaction do
        correct
        raise ActiveRecord::Rollback
      end
    end
    assert_nil @recording.reload.summary_refresh_due_at
    assert_equal before, @recording.transcript_text
  end

end
