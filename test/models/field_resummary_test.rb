require "test_helper"
require "support/field_recording_helpers"

class FieldResummaryTest < ActiveJob::TestCase

  include FieldRecordingHelpers
  include ActionCable::TestHelper

  # Every house call fails.
  class FailingInference

    def house_chat(**) = raise(UtilityInference::Error, "down")

  end

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @previous = ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"]
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = "test-key"
    FieldSummaries.live = true
    @recording = ready_recording(account: @account, user: @user)
    @recording.update_columns(summary_short: "Dad talk", summary_long: "A father and his daughter talk.",
                              summarized_at: 1.hour.ago, summary_attempts: 1)
  end

  teardown do
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = @previous
    FieldSummaries.live = false
  end

  test "asking again keeps the old summary on show and queues a fresh one" do
    assert_enqueued_with(job: FieldItems::SummarizeJob, args: [ @recording ]) do
      assert @recording.request_resummary!
    end
    @recording.reload
    assert_nil @recording.summarized_at
    assert_equal 0, @recording.summary_attempts
    assert_equal "A father and his daughter talk.", @recording.summary_long
    assert @recording.summary_pending?
  end

  test "the new summary replaces the old one once written" do
    @recording.request_resummary!
    claim = @recording.claim_summary!
    assert claim
    assert @recording.store_summary!(short: "Paulina and Dan", long: "Paulina tells Dan she wants to belong again.",
      input_digest: FieldSummaries.current_input_digest(@recording), claim:)
    @recording.reload
    assert_equal "Paulina tells Dan she wants to belong again.", @recording.summary_long
    assert_not @recording.summary_pending?
  end

  test "refused while a summary call is in flight, so repeated presses cost one call" do
    @recording.update_columns(summarized_at: nil, summary_claimed_at: 1.minute.ago)
    assert_no_enqueued_jobs(only: FieldItems::SummarizeJob) do
      assert_not @recording.request_resummary!
    end
  end

  test "a stale claim from a job that died doesn't block it" do
    @recording.update_columns(summarized_at: nil, summary_claimed_at: 1.hour.ago)
    assert @recording.request_resummary!
  end

  test "nothing to summarise, nothing queued" do
    @recording.update_columns(transcript_text: "")
    assert_no_enqueued_jobs(only: FieldItems::SummarizeJob) do
      assert_not @recording.request_resummary!
    end
  end

  test "the last attempt still reads as pending while its call is running" do
    @recording.update_columns(summarized_at: nil, summary_attempts: FieldSummarizable::MAX_ATTEMPTS,
                              summary_claimed_at: 1.minute.ago)
    assert @recording.summary_pending?
    assert_not @recording.summary_failed?
  end

  test "when every attempt fails, an open page is told and the old summary is offered again" do
    @recording.request_resummary!
    FieldSummarizable::MAX_ATTEMPTS.times do |n|
      assert @recording.reload.summary_pending?, "pending before attempt #{n + 1}"
      assert_broadcasts("Account:#{@account.obfuscated_id}", 1) do
        FieldItems::SummarizeJob.perform_now(@recording, inference: FailingInference.new)
      end
    end

    @recording.reload
    assert_not @recording.summary_pending?
    assert @recording.summary_failed?
    assert_equal "A father and his daughter talk.", @recording.summary_long
    assert @recording.request_resummary!, "asking again is allowed after a failure"
    assert_not @recording.reload.summary_failed?
  end

end
