require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::SuggestSpeakersJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  # Stands in for UtilityInference: returns what it's given, records the call,
  # and can run a block mid-call (to simulate a person acting meanwhile).
  class FakeInference

    attr_reader :calls

    def initialize(answer, during: nil)
      @answer, @during, @calls = answer, during, []
    end

    def structured(**kwargs)
      @calls << kwargs
      @during&.call
      raise @answer if @answer.is_a?(Exception)

      @answer
    end

  end

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = queued_recording(account: @account, user: @user, title: "Venue call with Priya")
    dispatch = @recording.claim_dispatch!
    @recording.accept_transcript!(dispatch, scribe_transcription(words: scribe_words(
      [ "speaker_0", 0.0, 0.4, "Priya," ], [ "speaker_0", 0.5, 0.9, "your" ], [ "speaker_0", 1.0, 1.4, "turn." ],
      [ "speaker_1", 2.0, 2.4, "Thanks." ], [ "speaker_1", 2.5, 2.9, "My" ], [ "speaker_1", 3.0, 3.4, "venue" ],
      [ "speaker_1", 3.5, 3.9, "contract" ], [ "speaker_1", 4.0, 4.4, "is" ], [ "speaker_1", 4.5, 4.9, "signed." ],
      [ "speaker_1", 5.0, 5.4, "Planning" ], [ "speaker_1", 5.5, 5.9, "starts." ]
    )))
    @recording.reload
    @first, @second = @recording.speakers.to_a
    @previous = ENV["SOULSHOUSE_FIELD_SUGGESTIONS"]
    ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] = "on"
  end

  teardown { ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] = @previous }

  def run_with(answer, **options)
    inference = FakeInference.new(answer, **options)
    FieldRecordings::SuggestSpeakersJob.perform_now(@recording.id, inference:)
    inference
  end

  def suggest(speaker: "S2", name: "Priya", quote: "my venue contract")
    { "suggestions" => [ { "speaker" => speaker, "name" => name, "quote" => quote } ] }
  end

  test "with the production gate off, no inference is contacted at all" do
    ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] = nil
    inference = run_with(suggest)
    assert_empty inference.calls
    assert_nil @recording.reload.suggestions_state
  end

  test "a supported suggestion stores the source excerpt itself, with its own time" do
    run_with(suggest(quote: "MY venue — contract!"))

    @second.reload
    assert_equal "Priya", @second.suggested_name
    assert_equal "My venue contract", @second.suggestion_quote, "the speaker's own words, not the model's rendering"
    assert_equal 2500, @second.suggestion_quote_ms
    assert_equal 0, @second.suggestion_generation
    assert_equal "Speaker 2", @second.display_name, "a suggestion is never a name"
    assert_no_match "Priya:", @recording.reload.transcript_text
  end

  test "one call per recording, claimed before it is made: duplicates and failures never call again" do
    first = run_with({ "suggestions" => [] })
    assert_equal 1, first.calls.size
    assert_equal "done", @recording.reload.suggestions_state
    assert_empty run_with(suggest).calls

    @recording.update_columns(suggestions_state: nil)
    run_with(UtilityInference::InvalidResponse.new("nope"))
    assert_equal "failed", @recording.reload.suggestions_state
    assert_empty run_with(suggest).calls
  end

  test "the model sees speaker tags, the title and capped known names, never the word ids" do
    state = run_with({ "suggestions" => [] }).calls.first[:state]
    assert_equal "Venue call with Priya", state[:title]
    assert_match "S1: Priya, your turn.", state[:transcript]
    assert_no_match "speaker_0", state[:transcript]
    assert_operator state[:names_this_field_knows].size, :<=, FieldRecordings::SuggestSpeakersJob::MAX_NAMES
  end

  test "names must be whole words that are known or appear; punctuation-only names never match" do
    run_with({ "suggestions" => [
      { "speaker" => "S2", "name" => "Ann", "quote" => "Planning starts" }, # 'ann' only inside 'planning'
      { "speaker" => "S2", "name" => "...", "quote" => "my venue contract" },
      { "speaker" => "S2", "name" => "Bartholomew", "quote" => "venue contract" }
    ] })
    assert_nil @second.reload.suggested_name
  end

  test "quotes the speaker never said, named speakers, unknown tags and junk are dropped" do
    @first.name_as!(@account.field_voices.create!(name: "Sam"), by: @user)
    run_with({ "suggestions" => [
      { "speaker" => "S2", "name" => "Priya", "quote" => "your turn" },
      { "speaker" => "S1", "name" => "Priya", "quote" => "your turn" },
      { "speaker" => "S9", "name" => "Priya", "quote" => "is signed" },
      "junk"
    ] })
    assert_nil @second.reload.suggested_name
    assert_nil @first.reload.suggested_name
  end

  test "a late answer never overrides a decision made while the call was out" do
    run_with(suggest, during: -> { @second.name_as!(@account.field_voices.create!(name: "Tomás"), by: @user) })
    assert_equal "Tomás", @second.reload.display_name
    assert_nil @second.suggested_name

    @recording.update_columns(suggestions_state: nil)
    run_with(suggest, during: -> { @second.reload.unname! }) # named, then un-named: still a decision
    assert_nil @second.reload.suggested_name, "a correction back to 'Speaker 2' is respected too"
  end

  test "a dismissed suggestion is never recreated by a later call" do
    run_with(suggest)
    assert @second.reload.dismiss_suggestion!(@second.decision_generation)
    @recording.update_columns(suggestions_state: nil)
    run_with(suggest)
    assert_nil @second.reload.suggested_name
  end

  test "a suggestion naming a known voice uses its spelling but links nothing by itself" do
    @account.field_voices.create!(name: "Priya")
    run_with(suggest(name: "priya"))
    assert_equal "Priya", @second.reload.suggested_name
    assert_nil @second.suggested_voice_id
  end

  test "an accepted transcript queues suggestions only when the gate is on" do
    fresh = queued_recording(account: @account, user: @user)
    assert_enqueued_with(job: FieldRecordings::SuggestSpeakersJob, args: [ fresh.id ]) do
      FieldRecording::TranscriptReceiver.receive!(fresh.claim_dispatch!, scribe_transcription)
    end

    clear_enqueued_jobs
    ENV["SOULSHOUSE_FIELD_SUGGESTIONS"] = nil
    other = queued_recording(account: @account, user: @user)
    FieldRecording::TranscriptReceiver.receive!(other.claim_dispatch!, scribe_transcription)
    assert_no_enqueued_jobs(only: FieldRecordings::SuggestSpeakersJob)
  end

end
