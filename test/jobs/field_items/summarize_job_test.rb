require "test_helper"
require "support/field_recording_helpers"

class FieldItems::SummarizeJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers
  include ActionCable::TestHelper

  # Stands in for UtilityInference: records each house call and answers.
  class FakeInference

    attr_reader :calls

    # One answer for every call, or an array answered in turn.
    def initialize(answer)
      @answers, @calls = Array(answer), []
    end

    def house_chat(**kwargs)
      @calls << kwargs
      answer = @answers[[ @calls.size - 1, @answers.size - 1 ].min]
      raise answer if answer.is_a?(Exception)

      answer
    end

  end

  GOOD = '{"short": "Orchard replanting plan.", "sentence": "A plan for replanting the north orchard with pears next spring."}'

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @previous = ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"]
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = "test-key"
    FieldSummaries.live = true
  end

  teardown do
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = @previous
    FieldSummaries.live = false
  end

  def text_file(body = "We replant the north orchard with pears in March.", name: "orchard.md")
    file = @account.field_files.create!(file: upload(name, body), uploaded_by: @user, note: "for the spring")
    file.update_columns(extracted_text: body, text_extracted_at: Time.current)
    file
  end

  def upload(name, body, type = "text/plain")
    io = Tempfile.new([ "field", File.extname(name) ])
    io.binmode
    io.write(body)
    io.rewind
    Rack::Test::UploadedFile.new(io.path, type, original_filename: name)
  end

  def run_with(item, answer)
    inference = FakeInference.new(answer)
    FieldItems::SummarizeJob.perform_now(item, inference:)
    inference
  end

  test "a readable file gets both summaries from house Haiku, pinned to Anthropic" do
    file = text_file
    updated_at = file.reload.updated_at
    inference = nil
    assert_broadcasts("Account:#{@account.obfuscated_id}", 1) { inference = run_with(file, GOOD) }

    file.reload
    assert_equal "Orchard replanting plan", file.summary_short
    assert_equal "A plan for replanting the north orchard with pears next spring.", file.summary_long
    assert file.summarized_at
    assert_nil file.summary_claimed_at
    assert_equal updated_at, file.updated_at, "a summary is not an edit"

    call = inference.calls.sole
    assert_equal "anthropic/claude-haiku-5.5", call[:model]
    assert_equal "anthropic", call[:provider]
    assert_includes call[:user], "north orchard"
    assert_includes call[:user], "for the spring"
  end

  test "a ready recording is summarised from its transcript" do
    recording = ready_recording(account: @account, user: @user, title: "Morning call")
    inference = run_with(recording, GOOD)

    assert_equal "Orchard replanting plan", recording.reload.summary_short
    assert_includes inference.calls.sole[:user], recording.transcript_text.first(20)
    assert_includes inference.calls.sole[:user], "recording transcript"
  end

  test "nothing readable, nothing sent: unread files and recordings not yet ready" do
    pdf = @account.field_files.create!(file: upload("deck.pdf", "%PDF-1.4".b, "application/pdf"), uploaded_by: @user)
    queued = queued_recording(account: @account, user: @user)

    assert_empty run_with(pdf, GOOD).calls
    assert_empty run_with(queued, GOOD).calls
    assert_equal 0, pdf.reload.summary_attempts
  end

  test "on by default with no setting, and never without a house key" do
    file = text_file
    assert FieldSummaries.enabled?
    assert_enqueued_with(job: FieldItems::SummarizeJob) { file.enqueue_summary }
    clear_enqueued_jobs

    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = nil
    HouseInference::Offering.stub(:key, nil) { assert_empty run_with(file, GOOD).calls }
    assert_nil file.reload.summarized_at
  end

  test "a summarised or discarded item is never summarised again" do
    file = text_file
    run_with(file, GOOD)
    assert_empty run_with(file.reload, GOOD).calls

    other = text_file(name: "other.md")
    other.discard
    assert_empty run_with(other, GOOD).calls
  end

  test "a fresh claim held by another job means no second call" do
    file = text_file
    file.update_columns(summary_claimed_at: 1.minute.ago, summary_attempts: 1)
    assert_empty run_with(file, GOOD).calls

    file.update_columns(summary_claimed_at: (FieldSummarizable::CLAIM_TTL + 1.minute).ago)
    assert_equal 1, run_with(file, GOOD).calls.size
    assert_equal 2, file.reload.summary_attempts
  end

  test "failures release the claim and count, and stop at the attempt cap" do
    file = text_file
    run_with(file, UtilityInference::InvalidResponse.new("boom"))
    run_with(file, "no json here")
    run_with(file, '{"short": "Orchard plan", "sentence": ""}')

    file.reload
    assert_equal FieldSummarizable::MAX_ATTEMPTS, file.summary_attempts
    assert_nil file.summary_claimed_at
    assert_nil file.summarized_at
    assert_empty run_with(file, GOOD).calls
  end

  test "long material is cut before it is sent" do
    file = text_file("word " * 10_000)
    user = run_with(file, GOOD).calls.sole[:user]
    assert_operator user.length, :<, FieldSummaries::MAX_SOURCE_CHARS + 500
    assert_includes user, "the rest is cut off"
  end

  test "parse holds the answer to the shapes we show" do
    assert_equal({ short: "Venue contract with Priya", long: "Priya and Sam go over the venue contract." },
      FieldSummaries.parse("Sure!\n{\"short\": \"Venue contract with Priya.\", \"sentence\": \"Priya and Sam go over the venue contract.\"}"))
    assert_equal "Six words is over the limit", FieldSummaries.parse('{"short": "Six words is over the limit", "sentence": "x"}')[:short],
      "word count is summarize's job, so a long short answer isn't thrown away"
    assert_raises(UtilityInference::InvalidResponse) { FieldSummaries.parse('{"short": "", "sentence": "x"}') }
    assert_raises(UtilityInference::InvalidResponse) { FieldSummaries.parse('{"short": 3, "sentence": "x"}') }
    assert_raises(UtilityInference::InvalidResponse) { FieldSummaries.parse('["short"]') }
    long = FieldSummaries.parse(%({"short": "Notes", "sentence": "#{'very ' * 200}long."}))[:long]
    assert_operator long.length, :<=, FieldSummaries::LONG_MAX_CHARS
  end

  test "a short summary over five words is asked for once more, with its count" do
    file = text_file
    long = '{"short": "Daniel and Anna on rest and album", "sentence": "A talk about rest and the album."}'
    fixed = '{"short": "Rest and the album", "sentence": "Another sentence."}'
    inference = run_with(file, [ long, fixed ])

    file.reload
    assert_equal "Rest and the album", file.summary_short
    assert_equal "A talk about rest and the album.", file.summary_long, "the first sentence is kept"
    assert_equal 2, inference.calls.size
    assert_includes inference.calls.last[:user], "has 7 words"
    assert_equal 1, file.summary_attempts, "the re-ask is part of one attempt"
  end

  test "still too long after the re-ask: the shorter answer is trimmed to five words" do
    file = text_file
    first = '{"short": "Daniel and Anna on rest and album", "sentence": "A talk."}'
    second = '{"short": "Album visual concept and the Introphoria", "sentence": "x"}'
    inference = run_with(file, [ first, second ])

    assert_equal "Album visual concept", file.reload.summary_short, "no dangling 'and the'"
    assert_equal 2, inference.calls.size
  end

  test "trim_short keeps five words and drops a dangling filler word or comma" do
    assert_equal "Dog, food, and a reading", FieldSummaries.trim_short("Dog, food, and a reading on death")
    assert_equal "Daniel and Anna talk album", FieldSummaries.trim_short("Daniel and Anna talk album, rest, control")
    assert_equal "Appel famille", FieldSummaries.trim_short("Appel famille et de la caméra")
    assert_equal "And", FieldSummaries.trim_short("And and and and and and")
  end

  test "extraction and a transcript becoming ready queue the summary" do
    assert_enqueued_with(job: FieldItems::SummarizeJob) do
      file = @account.field_files.create!(file: upload("plan.md", "the orchard plan"), uploaded_by: @user)
      file.extract_text!
    end

    clear_enqueued_jobs
    assert_enqueued_with(job: FieldItems::SummarizeJob) { ready_recording(account: @account, user: @user) }
  end

  test "the sweep queues only items that are readable, unsummarised, unclaimed and under the cap" do
    due = text_file(name: "due.md")
    done = text_file(name: "done.md").tap { |file| file.update_columns(summarized_at: Time.current) }
    capped = text_file(name: "capped.md").tap { |file| file.update_columns(summary_attempts: FieldSummarizable::MAX_ATTEMPTS) }
    claimed = text_file(name: "claimed.md").tap { |file| file.update_columns(summary_claimed_at: Time.current) }
    stale = text_file(name: "stale.md").tap { |file| file.update_columns(summary_claimed_at: 1.hour.ago, summary_attempts: 1) }
    empty = text_file("", name: "empty.md")
    gone = text_file(name: "gone.md").tap(&:discard)
    recording = ready_recording(account: @account, user: @user)
    queued_recording(account: @account, user: @user)
    clear_enqueued_jobs

    FieldItems::SummarySweepJob.perform_now
    queued = enqueued_jobs.select { |job| job["job_class"] == "FieldItems::SummarizeJob" }
      .map { |job| GlobalID::Locator.locate(job["arguments"].first["_aj_globalid"]) }
    assert_equal [ due, stale, recording ].map(&:to_global_id).sort_by(&:to_s), queued.map(&:to_global_id).sort_by(&:to_s)
    assert_not_includes queued, done
    assert_not_includes queued, capped
    assert_not_includes queued, claimed
    assert_not_includes queued, empty
    assert_not_includes queued, gone
  end

  test "whitespace-only files are retired, so they can't starve the sweep" do
    blanks = Array.new(FieldItems::SummarySweepJob::BATCH) { |i| text_file(" \n\t ", name: "blank-#{i}.md") }
    readable = text_file(name: "later.md")
    clear_enqueued_jobs

    FieldItems::SummarySweepJob.perform_now
    queued = enqueued_jobs.select { |job| job["job_class"] == "FieldItems::SummarizeJob" }
      .map { |job| job["arguments"].first["_aj_globalid"] }
    assert_includes queued, readable.to_global_id.to_s

    # Even if one slipped through the query, claiming it retires it without a call.
    blank = blanks.first
    assert_empty run_with(blank, GOOD).calls
    assert_equal FieldSummarizable::MAX_ATTEMPTS, blank.reload.summary_attempts
    assert_not_includes FieldFile.summary_due.pluck(:id), blank.id
  end

  test "the API and the Field page carry both summaries, null until written" do
    file = text_file
    assert_equal [ nil, nil ], FieldItems.file_json(file).values_at(:summary_short, :summary_long)
    run_with(file, GOOD)
    json = FieldItems.file_json(file.reload)
    assert_equal "Orchard replanting plan", json[:summary_short]
    assert_equal "A plan for replanting the north orchard with pears next spring.", json[:summary_long]

    recording = ready_recording(account: @account, user: @user)
    assert_nil FieldItems.recording_json(recording)[:summary_short]
  end

end
