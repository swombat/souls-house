require "test_helper"
require "support/field_recording_helpers"

class FieldSummaryFreshnessTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  GOOD = '{"short":"Orchard plan","sentence":"A plan for the orchard."}'

  class Inference

    attr_reader :calls

    def initialize(answer = GOOD, &during_call)
      @answer, @during_call, @calls = answer, during_call, []
    end

    def house_chat(**input)
      @calls << input
      @during_call&.call(input)
      raise @answer if @answer.is_a?(Exception)

      @answer
    end

  end

  setup do
    @account, @user = accounts(:personal_account), users(:user_1)
    @previous = ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"]
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = "test-key"
    FieldSummaries.live = true
    @recording = ready_recording(account: @account, user: @user)
    clear_enqueued_jobs
  end

  teardown do
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = @previous
    FieldSummaries.live = false
  end

  def summarize
    FieldItems::SummarizeJob.perform_now(@recording, inference: Inference.new)
    @recording.reload
  end

  # Transactional fixtures never really commit. Exercise the registered
  # callback here; FieldSummaryRefreshCommitTest tests real commit/rollback.
  def run_commit_callbacks(&block)
    ActiveRecord.stub(:after_all_transactions_commit, ->(&callback) { callback.call }, &block)
  end

  def correct(text = "good morning")
    @recording.reload
    line = @recording.transcript_lines.first
    @recording.correct_line!(line[:locator], text:, was: line[:text], revision: @recording.transcript_revision)
  end

  def at_check_time
    travel_to(@recording.reload.summary_refresh_due_at + 1.second) { yield }
  end

  test "freshness is absent without output, unknown for archive output, current with matching provenance" do
    assert_nil @recording.summary_freshness
    @recording.update_columns(summary_short: "Legacy", summarized_at: 1.hour.ago)
    assert_equal "unknown", @recording.summary_freshness
    assert_no_enqueued_jobs(only: FieldItems::SummarizeJob) { FieldItems::SummarySweepJob.perform_now }
    assert @recording.request_resummary!
    summarize
    assert_equal "current", @recording.summary_freshness
  end

  test "title and note affect provenance but neither schedules; Markdown notes are not inference input" do
    summarize
    assert_no_enqueued_jobs(only: FieldItems::RefreshSummaryJob) do
      @recording.update!(notes: "# Private authored notes")
      assert_equal "current", @recording.summary_freshness
      @recording.update!(title: "New title")
      assert_equal "stale", @recording.summary_freshness
      @recording.update!(title: "test_audio.webm", note: "new note")
      assert_equal "stale", @recording.summary_freshness
    end
    assert_nil @recording.summary_refresh_due_at
  end

  test "digest is of the captured sent input, not a source edited during generation" do
    inference = Inference.new do
      @recording.update!(transcript_text: "Different words while inference runs")
    end
    assert_no_enqueued_jobs(only: FieldItems::RefreshSummaryJob) do
      FieldItems::SummarizeJob.perform_now(@recording, inference:)
    end
    @recording.reload
    assert_equal FieldSummaries.input_digest(inference.calls.sole[:user]), @recording.summary_input_digest
    assert_equal "stale", @recording.summary_freshness
    assert @recording.summarized?
  end

  test "shortening reuses the captured base prompt and source provenance" do
    long_answer = '{"short":"One two three four five six seven","sentence":"An orchard plan."}'
    inference = Inference.new(long_answer) do
      @recording.update!(transcript_text: "Edited during first call")
    end
    FieldItems::SummarizeJob.perform_now(@recording, inference:)
    assert_equal 2, inference.calls.size
    assert inference.calls.last[:user].start_with?(inference.calls.first[:user])
    assert_equal FieldSummaries.input_digest(inference.calls.first[:user]), @recording.reload.summary_input_digest
    assert_equal "stale", @recording.summary_freshness
  end

  test "changes beyond the actual truncation boundary do not make output stale" do
    @recording.update_columns(transcript_text: "x" * FieldSummaries::MAX_SOURCE_CHARS + "old tail")
    summarize
    @recording.update!(transcript_text: "x" * FieldSummaries::MAX_SOURCE_CHARS + "new tail")
    assert_equal "current", @recording.summary_freshness
    @recording.update!(transcript_text: "y" + @recording.transcript_text[1..])
    assert_equal "stale", @recording.summary_freshness
  end

  test "a human correction schedules at thirty minutes without pending or blocking manual refresh" do
    summarize
    freeze_time do
      run_commit_callbacks do
        assert_enqueued_with(job: FieldItems::RefreshSummaryJob, args: [ @recording ], at: 30.minutes.from_now) { correct }
      end
      assert_equal "stale", @recording.reload.summary_freshness
      assert_not @recording.summary_pending?
      assert_not @recording.summary_failed?
      assert @recording.request_resummary!
      assert @recording.summary_pending?
    end
  end

  test "later corrections do not defer the first scheduled check" do
    summarize
    freeze_time do
      run_commit_callbacks { correct("first correction") }
      first_due = @recording.reload.summary_refresh_due_at
      travel 20.minutes
      run_commit_callbacks { correct("second correction") }
      assert_equal first_due, @recording.reload.summary_refresh_due_at
      travel_to(first_due + 1.second)
      inference = Inference.new
      FieldItems::RefreshSummaryJob.perform_now(@recording, inference:)
      assert_equal 1, inference.calls.size
      assert_includes inference.calls.sole[:user], "second correction"
    end
  end

  test "explicit later human edit establishes provenance for an unknown archive summary" do
    @recording.update_columns(summary_short: "Legacy", summarized_at: 1.hour.ago, summary_attempts: 3)
    run_commit_callbacks { correct }
    at_check_time do
      FieldItems::RefreshSummaryJob.perform_now(@recording, inference: Inference.new)
      assert_equal "current", @recording.reload.summary_freshness
      assert_equal 1, @recording.summary_attempts
    end
  end

  test "explicit per-recording naming, un-naming and the house's clear-match naming schedule; a machine write with no confirmer does not" do
    summarize
    voice = @account.field_voices.create!(name: "Priya")
    speaker = @recording.speakers.first
    run_commit_callbacks do
      assert_enqueued_with(job: FieldItems::RefreshSummaryJob) { speaker.name_as!(voice, by: @user) }
    end
    assert_equal "stale", @recording.reload.summary_freshness
    run_commit_callbacks { assert_enqueued_with(job: FieldItems::RefreshSummaryJob) { speaker.unname! } }

    @recording.update_columns(summary_refresh_due_at: nil)
    assert_no_enqueued_jobs(only: FieldItems::RefreshSummaryJob) do
      speaker.name_as!(voice, by: nil, source: "confirmed_recognition")
    end
    assert_equal "stale", @recording.reload.summary_freshness
    assert_nil @recording.summary_refresh_due_at

    # A clear voice match naming the speaker changes who the summary says
    # spoke, so it is refreshed like a person's naming.
    run_commit_callbacks { assert_enqueued_with(job: FieldItems::RefreshSummaryJob) { speaker.unname! } }
    @recording.update_columns(summary_refresh_due_at: nil)
    run_commit_callbacks do
      assert_enqueued_with(job: FieldItems::RefreshSummaryJob) do
        speaker.name_as!(voice, by: nil, source: "auto_recognition", confidence: 84)
      end
    end
    assert_equal 84, speaker.reload.auto_named_confidence
  end

  test "explicit line reassignment schedules" do
    summarize
    second = @recording.speakers.last
    run_commit_callbacks do
      assert_enqueued_with(job: FieldItems::RefreshSummaryJob) do
        @recording.reassign_line_number!(1, to: second, was: "hello", revision: @recording.transcript_revision)
      end
    end
    assert_equal "stale", @recording.reload.summary_freshness
  end

  test "explicit naming by a resident also schedules, while a no-op correction does not" do
    voice = @account.field_voices.create!(name: "Priya")
    run_commit_callbacks do
      assert_enqueued_with(job: FieldItems::RefreshSummaryJob) do
        @recording.speakers.first.name_as!(voice, by: agents(:research_assistant))
      end
      assert_no_enqueued_jobs(only: FieldItems::RefreshSummaryJob) { correct("hello") }
    end
  end

  test "attributed suggestion and recognition confirmations schedule delayed refreshes" do
    voice = @account.field_voices.create!(name: "Priya")
    first, second = @recording.speakers.to_a
    run_commit_callbacks do
      assert_enqueued_with(job: FieldItems::RefreshSummaryJob) do
        first.name_as!(voice, by: @user, source: "confirmed_suggestion")
      end
    end
    assert_equal "confirmed_suggestion", first.reload.naming_source
    store_print!(voice)
    second.update!(recognised_voice: voice, recognition_confidence: 80,
      recognition_print_generation: voice.reload.print_generation,
      recognition_decision_generation: second.decision_generation,
      recognition_cohort: FieldVoiceprints::Cohort.active(@account).last)
    shown = second.reload.recognition_token
    with_recognition(@account) do
      run_commit_callbacks do
        assert_enqueued_with(job: FieldItems::RefreshSummaryJob) do
          assert second.confirm_recognition!(by: @user, shown:)
        end
      end
    end
    assert_equal "confirmed_recognition", second.reload.naming_source
  end

  test "voice rename rerender and identity deletion mark stale but never queue summary fanouts" do
    voice = @account.field_voices.create!(name: "Priya")
    @recording.speakers.first.name_as!(voice, by: nil, source: "confirmed_recognition")
    summarize
    clear_enqueued_jobs
    assert_no_enqueued_jobs(only: FieldItems::RefreshSummaryJob) do
      voice.update!(name: "Sam")
      FieldRecordings::RerenderTranscriptsJob.perform_now(voice.id)
      assert_equal "stale", @recording.reload.summary_freshness
      voice.delete_identity!
    end
    assert_nil @recording.reload.summary_refresh_due_at
    assert_equal "stale", @recording.summary_freshness
  end

  test "stale output with no human authorization and unknown archives are not automatically refreshed" do
    summarize
    @recording.update!(transcript_text: "A fanout edit")
    inference = Inference.new
    FieldItems::RefreshSummaryJob.perform_now(@recording, inference:)
    assert_empty inference.calls
    @recording.update_columns(summary_input_digest: nil)
    FieldItems::RefreshSummaryJob.perform_now(@recording, inference:)
    assert_empty inference.calls
  end

  test "automatic failures retain old output and duplicates cannot reset the three attempt cap" do
    summarize
    old_output = @recording.summary_long
    run_commit_callbacks { correct }
    at_check_time do
      inference = Inference.new(UtilityInference::Error.new("down"))
      5.times { FieldItems::RefreshSummaryJob.perform_now(@recording.reload, inference:) }
      assert_equal 3, inference.calls.size
      assert_equal 3, @recording.reload.summary_attempts
      assert_equal old_output, @recording.summary_long
      assert @recording.summary_failed?
      assert_not @recording.summary_pending?
      assert_equal "stale", @recording.summary_freshness
      assert_not_includes FieldRecording.summary_due.pluck(:id), @recording.id
    end
  end

  test "a disabled discarded unreadable or already current item is not admitted" do
    summarize
    run_commit_callbacks { correct }
    at_check_time do
      inference = Inference.new
      FieldSummaries.stub(:enabled?, false) { FieldItems::RefreshSummaryJob.perform_now(@recording, inference:) }
      assert_empty inference.calls
      @recording.update_columns(discarded_at: Time.current)
      FieldItems::RefreshSummaryJob.perform_now(@recording, inference:)
      assert_empty inference.calls
      @recording.update_columns(discarded_at: nil, transcript_text: "")
      FieldItems::RefreshSummaryJob.perform_now(@recording, inference:)
      assert_empty inference.calls
      @recording.update_columns(transcript_text: "restored")
      @recording.update_columns(summary_input_digest: FieldSummaries.current_input_digest(@recording))
      FieldItems::RefreshSummaryJob.perform_now(@recording, inference:)
      assert_empty inference.calls
      assert_nil @recording.reload.summary_refresh_due_at
    end
  end

  test "delayed check never overlaps a manual call and arranges only one TTL recheck" do
    summarize
    @recording.request_resummary!
    run_commit_callbacks { correct }
    at_check_time do
      claim = @recording.claim_summary!
      inference = Inference.new
      assert_enqueued_with(job: FieldItems::RefreshSummaryJob, args: [ @recording, { recheck: true } ],
        at: 15.minutes.from_now + 1.second) do
        FieldItems::RefreshSummaryJob.perform_now(@recording, inference:)
      end
      assert_no_enqueued_jobs(only: FieldItems::RefreshSummaryJob) do
        FieldItems::RefreshSummaryJob.perform_now(@recording, recheck: true, inference:)
      end
      assert_empty inference.calls
      assert_equal claim, @recording.reload.summary_claim_token
      assert_equal 1, @recording.summary_attempts
    end
  end

  test "late stale manual result queues an authorized check even after the TTL recheck was spent" do
    summarize
    @recording.request_resummary!
    claim = @recording.claim_summary!
    earlier_input = FieldSummaries.current_input_digest(@recording)
    run_commit_callbacks { correct }
    at_check_time do
      # Existing worker's result is still accepted if no newer claim owns it.
      run_commit_callbacks do
        assert_enqueued_with(job: FieldItems::RefreshSummaryJob) do
          assert @recording.store_summary!(short: "Old", long: "Old result", input_digest: earlier_input, claim:)
        end
      end
      assert_equal "stale", @recording.reload.summary_freshness
      run_commit_callbacks { FieldItems::RefreshSummaryJob.perform_now(@recording, inference: Inference.new) }
      assert_equal "current", @recording.reload.summary_freshness
    end
  end

  test "edits during automatic generation stay stale and get their own authorized followup" do
    summarize
    run_commit_callbacks { correct }
    at_check_time do
      inference = Inference.new { correct("changed again") }
      run_commit_callbacks { FieldItems::RefreshSummaryJob.perform_now(@recording, inference:) }
      assert_equal "stale", @recording.reload.summary_freshness
      assert_equal FieldSummaries.input_digest(inference.calls.sole[:user]), @recording.summary_input_digest
      assert @recording.summary_refresh_due_at
      followup = Inference.new
      run_commit_callbacks { FieldItems::RefreshSummaryJob.perform_now(@recording, inference: followup) }
      assert_empty followup.calls, "the in-call edit gets its own thirty-minute delay"
      travel 30.minutes
      run_commit_callbacks { FieldItems::RefreshSummaryJob.perform_now(@recording, inference: followup) }
      assert_equal 1, followup.calls.size
      assert_equal "current", @recording.reload.summary_freshness
    end
  end

  test "expired worker cannot overwrite or release the newer owning claim" do
    old_claim = @recording.claim_summary!
    old_input = FieldSummaries.current_input_digest(@recording)
    @recording.update_columns(summary_claimed_at: 16.minutes.ago)
    new_claim = @recording.reload.claim_summary!
    assert_not_equal old_claim, new_claim
    assert_not @recording.store_summary!(short: "Old", long: "Old", input_digest: old_input, claim: old_claim)
    assert_not @recording.release_summary_claim!(claim: old_claim)
    assert_equal new_claim, @recording.reload.summary_claim_token
    assert @recording.store_summary!(short: "New", long: "New", input_digest: old_input, claim: new_claim)
    assert_equal "New", @recording.reload.summary_short
  end

  test "an edit during a delayed regeneration waits thirty minutes not the length of one call" do
    summarize
    run_commit_callbacks do
      correct("first correction")
      clear_enqueued_jobs
      at_check_time do
        edited_at = nil
        inference = Inference.new do
          edited_at = Time.current
          correct("second correction during the call")
        end
        FieldItems::RefreshSummaryJob.perform_now(@recording, inference:)
        times = enqueued_jobs.select { it["job_class"] == "FieldItems::RefreshSummaryJob" }
          .map { Time.iso8601(it["scheduled_at"]) }
        assert_not_empty times
        assert_empty times.select { it < edited_at + 30.minutes }
      end
    end
  end

  test "duplicates cannot reset or take a second claim during an automatic refresh" do
    summarize
    run_commit_callbacks { correct }
    at_check_time do
      duplicate = Inference.new
      inference = Inference.new do
        FieldItems::RefreshSummaryJob.perform_now(FieldRecording.find(@recording.id), recheck: true, inference: duplicate)
      end
      run_commit_callbacks { FieldItems::RefreshSummaryJob.perform_now(@recording, inference:) }
      assert_empty duplicate.calls
      assert_equal 1, @recording.reload.summary_attempts
      assert_equal "current", @recording.summary_freshness
    end
  end

  test "a stale result for the same admitted input retries without resetting its budget" do
    summarize
    run_commit_callbacks { correct }
    at_check_time do
      target_digest = FieldSummaries.current_input_digest(@recording)
      claim = @recording.claim_stale_summary!
      assert claim
      run_commit_callbacks do
        @recording.store_summary!(short: "Other input", long: "Captured during an interleaved change",
          input_digest: "a" * 64, claim:)
      end
      assert_equal target_digest, @recording.reload.summary_refresh_digest
      assert_equal "stale", @recording.summary_freshness
      assert @recording.claim_stale_summary!
      assert_equal 2, @recording.reload.summary_attempts
    end
  end

end
