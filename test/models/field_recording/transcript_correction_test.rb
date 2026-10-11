require "test_helper"
require "support/field_recording_helpers"

class FieldRecording::TranscriptCorrectionTest < ActiveSupport::TestCase

  include FieldRecordingHelpers
  include ActiveJob::TestHelper

  setup do
    @user = users(:user_1)
    @account = agents(:research_assistant).account
    @recording = queued_recording(account: @account, user: @user, title: "Sanda")
    words = scribe_words([ "speaker_0", 0.0, 0.5, "j'ai" ], [ "speaker_0", 0.6, 1.2, "cinquante" ],
      [ "speaker_0", 1.3, 1.8, "kilos" ], [ "speaker_1", 3.0, 3.4, "oui" ])
    @recording.accept_transcript!(@recording.claim_dispatch!, scribe_transcription(words:))
    @recording.reload
    # 0 j'ai, 1 spacing, 2 cinquante, 3 spacing, 4 kilos, 5 spacing, 6 oui
  end

  test "a word is corrected in place: its timing kept, marked, the text and revision moved on" do
    original = @recording.transcript_words.deep_dup
    talk = @recording.speakers.map(&:talk_ms)
    row = @recording.correct_transcript!(revision: 0, corrections: [ { from: 2, to: 2, text: "soixante-dix" } ], by: @user)

    @recording.reload
    assert_equal 1, @recording.transcript_revision
    assert_equal({ "s" => 600, "e" => 1200, "t" => "soixante-dix", "k" => "w", "spk" => "speaker_0", "c" => true },
      @recording.transcript_words[2])
    assert_equal "[00:00] Speaker 1: j'ai soixante-dix kilos\n[00:03] Speaker 2: oui", @recording.transcript_text
    assert_equal talk, @recording.speakers.reload.map(&:talk_ms), "talk time is not recomputed from a correction"
    assert_equal [ original[2] ], row.edits.first["before"], "the full original entry is kept"
    assert_equal [ "correction", 0, 1, @user ], [ row.kind, row.base_revision, row.revision, row.corrected_by ]
  end

  test "a run collapses into one corrected word with the run's outer timing" do
    @recording.correct_transcript!(revision: 0, corrections: [ { from: 2, to: 4, text: "soixante-dix kilos" } ], by: @user)
    words = @recording.reload.transcript_words
    assert_equal 5, words.size
    assert_equal [ 600, 1800, "soixante-dix kilos", true ], words[2].values_at("s", "e", "t", "c")
  end

  test "a batch refers to one revision and applies from the end; empty text removes a run" do
    @recording.correct_transcript!(revision: 0, by: @user,
      corrections: [ { from: 4, to: 4, text: "kg" }, { from: 0, to: 2, text: "" } ])
    assert_equal "[00:01] Speaker 1: kg\n[00:03] Speaker 2: oui", @recording.reload.transcript_text
  end

  test "stale, overlapping, cross-turn and spacing-edged corrections are refused and change nothing" do
    before = @recording.transcript_words.deep_dup
    error = assert_raises(FieldRecording::TranscriptCorrection::Stale) do
      @recording.correct_transcript!(revision: 3, corrections: [ { from: 2, to: 2, text: "x" } ], by: @user)
    end
    assert_equal 0, error.revision

    [
      [ { from: 0, to: 2, text: "a" }, { from: 2, to: 4, text: "b" } ],
      [ { from: 4, to: 6, text: "kilos oui" } ],
      [ { from: 1, to: 2, text: "x" } ],
      [ { from: 2, to: 99, text: "x" } ],
      [ { from: 2, text: "x" } ]
    ].each do |corrections|
      assert_raises(FieldRecording::TranscriptCorrection::Invalid, corrections.inspect) do
        @recording.correct_transcript!(revision: 0, corrections:, by: @user)
      end
    end
    assert_raises(FieldRecording::TranscriptCorrection::Invalid) do
      @recording.correct_transcript!(revision: nil, corrections: [ { from: 2, to: 2, text: "x" } ], by: @user)
    end

    @recording.reload
    assert_equal before, @recording.transcript_words
    assert_equal 0, @recording.transcript_revision
    assert_empty @recording.transcript_corrections
  end

  test "undo restores the latest batch exactly, is itself recorded, and only goes back once" do
    original = @recording.transcript_words.deep_dup
    text = @recording.transcript_text
    correction = @recording.correct_transcript!(revision: 0, by: @user,
      corrections: [ { from: 0, to: 0, text: "J'avais" }, { from: 2, to: 4, text: "soixante-dix kilos" } ])

    assert_raises(FieldRecording::TranscriptCorrection::Stale) { @recording.undo_transcript_correction!(revision: 0, by: @user) }
    undo = @recording.undo_transcript_correction!(revision: 1, by: @user)

    @recording.reload
    assert_equal original, @recording.transcript_words
    assert_equal text, @recording.transcript_text
    assert_equal 2, @recording.transcript_revision
    assert_equal [ "undo", correction ], [ undo.kind, undo.undoes ]
    assert correction.reload.undone_at
    assert_nil @recording.undoable_correction
    assert_raises(FieldRecording::TranscriptCorrection::NothingToUndo) do
      @recording.undo_transcript_correction!(revision: 2, by: @user)
    end
  end

  test "a supplied transcript is corrected turn by turn, and undone" do
    supplied = FieldRecording::Upload.claim!(
      account: @account, user: @user, signed_id: pinned_blob(account: @account, user: @user).signed_id,
      attributes: { title: "Archive" }, supplied_turns: FieldRecording::SuppliedTranscript.parse("Anna: Fifty kilos.\nDaniel: Right.\nAnna: Yes.")
    )
    supplied.correct_transcript!(revision: 0, corrections: [ { turn: 0, text: "Seventy kilos." } ], by: @user)
    assert_equal "Anna: Seventy kilos.\nDaniel: Right.\nAnna: Yes.", supplied.reload.transcript_text

    assert_raises(FieldRecording::TranscriptCorrection::Invalid) do
      supplied.correct_transcript!(revision: 1, corrections: [ { turn: 1, text: "  " } ], by: @user)
    end
    supplied.undo_transcript_correction!(revision: 1, by: @user)
    assert_equal "Anna: Fifty kilos.\nDaniel: Right.\nAnna: Yes.", supplied.reload.transcript_text
  end

  test "a correction clears and requeues a summary of the old words, and an older in-flight summary can't land" do
    FieldSummaries.stub(:enabled?, true) do
      @recording.update_columns(summary_short: "Fifty kilos", summary_long: "She said fifty.", summarized_at: Time.current)
      assert_enqueued_with(job: FieldItems::SummarizeJob) do
        @recording.correct_transcript!(revision: 0, corrections: [ { from: 2, to: 2, text: "soixante-dix" } ], by: @user)
      end
      @recording.reload
      assert_nil @recording.summary_short
      assert_nil @recording.summarized_at

      assert_not @recording.store_summary!(short: "Fifty kilos", long: "She said fifty.", revision: 0),
        "a summary written from revision 0 is refused at revision 1"
      assert @recording.store_summary!(short: "Seventy kilos", long: "She said seventy.", revision: 1)
    end
  end

  test "an unsummarised recording is left to the normal summary path" do
    FieldSummaries.stub(:enabled?, true) do
      assert_no_enqueued_jobs(only: FieldItems::SummarizeJob) do
        @recording.correct_transcript!(revision: 0, corrections: [ { from: 2, to: 2, text: "soixante-dix" } ], by: @user)
      end
    end
  end

end
