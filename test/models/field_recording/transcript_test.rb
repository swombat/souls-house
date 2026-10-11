require "test_helper"
require "support/field_recording_helpers"

class FieldRecording::TranscriptTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  test "words compact to ms integers and keep Scribe's speaker labels" do
    words = FieldRecording::Transcript.compact(scribe_words([ "speaker_0", 0.25, 0.5, "hi" ]) +
      [ { "type" => "audio_event", "text" => "(laughter)", "start" => 1, "end" => 2, "speaker_id" => "speaker_1" },
        { "type" => "mystery" } ])

    assert_equal [ { "s" => 250, "e" => 500, "t" => "hi", "k" => "w", "spk" => "speaker_0" },
                   { "s" => 1000, "e" => 2000, "t" => "(laughter)", "k" => "a", "spk" => "speaker_1" } ], words
  end

  test "speakers come in order of appearance with talk time and an isolated clip" do
    words = FieldRecording::Transcript.compact(scribe_words(
      [ "speaker_1", 0.0, 1.0, "first" ],
      [ "speaker_0", 1.2, 1.5, "interrupt" ],
      [ "speaker_1", 10.0, 18.0, "long" ],
      [ "speaker_0", 30.0, 31.0, "later" ]
    ))
    speakers = FieldRecording::Transcript.speakers(words)

    assert_equal [ "speaker_1", "speaker_0" ], speakers.map { |s| s[:label] }
    one = speakers.first
    assert_equal 9_000, one[:talk_ms]
    assert_equal 10_000, one[:clip_start_ms]
    assert_equal 15_000, one[:clip_end_ms], "clips are at most five seconds"
    assert_equal 30_000, speakers.last[:clip_start_ms], "the clean turn wins over the one next to someone else"
  end

  test "rendering uses the names given and marks the time of each turn" do
    words = FieldRecording::Transcript.compact(scribe_words(
      [ "speaker_0", 0.0, 0.4, "Hello" ], [ "speaker_0", 0.5, 0.9, "there." ], [ "speaker_1", 65.0, 65.5, "Hi." ]
    ))
    text = FieldRecording::Transcript.render(words, { "speaker_0" => "Speaker 1", "speaker_1" => "Speaker 2" })
    assert_equal "[00:00] Speaker 1: Hello there.\n[01:05] Speaker 2: Hi.", text
  end

  test "two labels with one identity read as one speaker, and their turns join" do
    words = FieldRecording::Transcript.compact(scribe_words(
      [ "speaker_0", 0.0, 0.4, "Hello" ], [ "speaker_2", 0.6, 1.0, "again." ], [ "speaker_1", 2.0, 2.4, "Hi." ],
      [ "speaker_2", 3.0, 3.4, "Bye." ]
    ))
    names = { "speaker_0" => "Ioan", "speaker_1" => "Daniel", "speaker_2" => "Ioan" }
    keys = { "speaker_0" => [ :voice, 1 ], "speaker_1" => [ :speaker, "speaker_1" ], "speaker_2" => [ :voice, 1 ] }

    assert_equal "[00:00] Ioan: Hello again.\n[00:02] Daniel: Hi.\n[00:03] Ioan: Bye.",
      FieldRecording::Transcript.render(words, names, keys)
    assert_equal "[00:00] Ioan: Hello\n[00:00] Ioan: again.\n[00:02] Daniel: Hi.\n[00:03] Ioan: Bye.",
      FieldRecording::Transcript.render(words, names), "without keys, labels stay apart"
  end

  test "a speaker who is never heard alone gets no clip rather than someone else's voice" do
    words = FieldRecording::Transcript.compact(scribe_words(
      [ "speaker_0", 0.0, 2.0, "talking" ], [ "speaker_1", 2.3, 2.6, "yes" ], [ "speaker_0", 2.9, 4.0, "over" ]
    ))
    quiet = FieldRecording::Transcript.speakers(words).find { |s| s[:label] == "speaker_1" }
    assert_nil quiet[:clip_start_ms]
    assert_nil quiet[:clip_end_ms]
  end

end
