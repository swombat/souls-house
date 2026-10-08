require "test_helper"
require "support/field_recording_helpers"

class FieldRecordings::SuggestSpeakersJobTest < ActiveJob::TestCase

  include FieldRecordingHelpers

  # Stands in for UtilityInference: returns what it's given, records the call.
  class FakeInference

    attr_reader :calls

    def initialize(answer) = (@answer, @calls = answer, [])

    def structured(**kwargs)
      @calls << kwargs
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
      [ "speaker_1", 3.5, 3.9, "contract" ], [ "speaker_1", 4.0, 4.4, "is" ], [ "speaker_1", 4.5, 4.9, "signed." ]
    )))
    @recording.reload
    @first, @second = @recording.speakers.to_a
  end

  def run_with(answer)
    inference = FakeInference.new(answer)
    FieldRecordings::SuggestSpeakersJob.perform_now(@recording.id, inference:)
    inference
  end

  test "a supported suggestion is stored beside the speaker, with where the quote starts" do
    run_with({ "suggestions" => [ { "speaker" => "S2", "name" => "Priya", "quote" => "my venue contract" } ] })

    @second.reload
    assert_equal "Priya", @second.suggested_name
    assert_equal "my venue contract", @second.suggestion_quote
    assert_equal 2500, @second.suggestion_quote_ms
    assert_equal "Speaker 2", @second.display_name, "a suggestion is never a name"
    assert_no_match "Priya:", @recording.reload.transcript_text
  end

  test "the model sees speaker tags, the title and known names, never the word ids" do
    inference = run_with({ "suggestions" => [] })
    state = inference.calls.first[:state]
    assert_equal "Venue call with Priya", state[:title]
    assert_match "S1: Priya, your turn.", state[:transcript]
    assert_no_match "speaker_0", state[:transcript]
  end

  test "quotes the speaker never said, names from nowhere, and named speakers are all dropped" do
    @first.name_as!(@account.field_voices.create!(name: "Sam"), by: @user)
    run_with({ "suggestions" => [
      { "speaker" => "S2", "name" => "Priya", "quote" => "your turn" },          # S1 said it, not S2
      { "speaker" => "S2", "name" => "Bartholomew", "quote" => "venue contract" }, # name appears nowhere
      { "speaker" => "S1", "name" => "Priya", "quote" => "your turn" },          # S1 is named already
      { "speaker" => "S9", "name" => "Priya", "quote" => "signed" },             # no such speaker
      "junk"
    ] })

    assert_nil @second.reload.suggested_name
    assert_nil @first.reload.suggested_name
  end

  test "a suggestion naming a voice this Field knows points at that voice" do
    priya = @account.field_voices.create!(name: "Priya")
    run_with({ "suggestions" => [ { "speaker" => "S2", "name" => "priya", "quote" => "My venue contract is signed" } ] })
    assert_equal priya, @second.reload.suggested_voice
    assert_equal "Priya", @second.suggested_name
  end

  test "a failed call does nothing visible" do
    run_with(UtilityInference::InvalidResponse.new("nope"))
    assert_nil @second.reload.suggested_name
    assert @recording.reload.ready?
  end

  test "an accepted transcript queues suggestions" do
    fresh = queued_recording(account: @account, user: @user)
    dispatch = fresh.claim_dispatch!
    assert_enqueued_with(job: FieldRecordings::SuggestSpeakersJob, args: [ fresh.id ]) do
      FieldRecording::TranscriptReceiver.receive!(dispatch, scribe_transcription)
    end
  end

end
