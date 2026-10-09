require "test_helper"

# The transcript shapes in the archive (swombat/pa), each in a line or two.
class FieldRecording::SuppliedTranscriptTest < ActiveSupport::TestCase

  Parse = FieldRecording::SuppliedTranscript

  test "bold Scribe-style speakers" do
    turns = Parse.parse("**Speaker A**: Um, I didn't spray?\n\n**Speaker B**: Just put these over here.\n\n**Speaker A**: Okay.")
    assert_equal [ "Speaker A", "Speaker B", "Speaker A" ], turns.map { |turn| turn["spk"] }
    assert_equal "Um, I didn't spray?", turns.first["t"]
    assert turns.all? { |turn| turn["s"].nil? }
  end

  test "bracketed and bare timestamps give each turn its start" do
    turns = Parse.parse("[00:04] speaker_0: I wanted her there.\n[01:07] speaker_1: Oh.\n[1:02:03] speaker_0: Later.")
    assert_equal [ 4_000, 67_000, 3_723_000 ], turns.map { |turn| turn["s"] }

    turns = Parse.parse("00:00 Daniel: [cutlery]\n\n00:21 Anna: How am I feeling?\n\n00:22 Daniel: Mm-hmm.")
    assert_equal [ [ "Daniel", 0 ], [ "Anna", 21_000 ], [ "Daniel", 22_000 ] ], turns.map { |turn| [ turn["spk"], turn["s"] ] }
  end

  test "a header of one-off labels is kept as one unattributed turn, not as speakers" do
    text = "# Conversation\nSource: ~/dev/pa/media/audio/x.mp3 (TileRec)\nSpeakers: Anna / Daniel\n\n" \
           "00:00 Daniel: Hi.\n00:05 Anna: Hello.\n00:09 Daniel: Shall we?"
    turns = Parse.parse(text)
    assert_nil turns.first["spk"]
    assert_includes turns.first["t"], "Source: ~/dev/pa/media/audio/x.mp3"
    assert_equal %w[Daniel Anna], Parse.speakers(turns).map { |speaker| speaker[:label] }
  end

  test "Meet notes: header blocks, vertical-tab turns, and a time alone on a line dates the next turn" do
    text = "# 'Coal Dust' - Transcript\n**Date:** 2026-03-25\n\n---\n\nTitle: Coal Dust\nID: 128LHSD\n====\n\n" \
           "Coal Dust - Transcript\n00:00:00\n \vDaniel Tenner: Hello.\vSteve Leung: Hello.\v \n" \
           "00:04:13\n \vDaniel Tenner: This one.\vSteve Leung: Yeah."
    turns = Parse.parse(text)
    assert_equal "# 'Coal Dust' - Transcript\nDate: 2026-03-25\n---\nTitle: Coal Dust\nID: 128LHSD\n====", turns.first["t"]
    assert_equal [ nil, "Coal Dust - Transcript" ], turns.second.values_at("spk", "t")
    spoken = turns.drop(2)
    assert_equal [ "Daniel Tenner", "Steve Leung", "Daniel Tenner", "Steve Leung" ], spoken.map { |turn| turn["spk"] }
    assert_equal [ 0, nil, 253_000, nil ], spoken.map { |turn| turn["s"] }
  end

  # Mira's round-1 cases: a speaker heard once, first, is speech, not header,
  # and keeps their time whichever way it was written.
  test "an opening speaker heard only once keeps their name and time" do
    turns = Parse.parse("[00:01] Alice: Opening.\n[00:02] Bob: Reply.\n[00:03] Bob: Again.")
    assert_equal [ [ "Alice", 1_000 ], [ "Bob", 2_000 ], [ "Bob", 3_000 ] ], turns.map { |turn| turn.values_at("spk", "s") }

    turns = Parse.parse("00:00:00\nAlice: Opening.\n00:00:05\nBob: Reply.\n00:00:10\nBob: Again.")
    assert_equal [ [ "Alice", 0 ], [ "Bob", 5_000 ], [ "Bob", 10_000 ] ], turns.map { |turn| turn.values_at("spk", "s") }

    turns = Parse.parse("Alice: Opening.\n\nBob: Reply.\n\nBob: Again.")
    assert_equal %w[Alice Bob Bob], turns.map { |turn| turn["spk"] }
  end

  test "bold around the time and the label together" do
    turns = Parse.parse("*Labels pending*\n\n**[00:00] speaker_0:** Hello.\n\n**[00:05] speaker_1:** Hi.\n\n**[00:09] speaker_0:** Bye.")
    assert_equal [ [ nil, nil ], [ "speaker_0", 0 ], [ "speaker_1", 5_000 ], [ "speaker_0", 9_000 ] ],
      turns.map { |turn| turn.values_at("spk", "s") }
    assert_equal "*Labels pending*", turns.first["t"]
  end

  test "prose stays prose: one label is not a conversation, and sentences aren't names" do
    turns = Parse.parse("Note: this was recorded badly.\n\nThen he said: no, never.\n\nWe left.")
    assert_equal [ nil ], turns.map { |turn| turn["spk"] }.uniq
    assert_equal 3, turns.size
  end

  test "markdown notes are not speakers" do
    text = "Daniel Tenner: Start.\nObie Fernandez: Sure.\n- Goal: ship it\n### Vision: one app\n3. **Fraud**: watch it\n" \
           "Daniel Tenner: Done."
    assert_equal [ "Daniel Tenner", "Obie Fernandez" ], Parse.speakers(Parse.parse(text)).map { |speaker| speaker[:label] }
  end

  test "unlabelled lines continue the turn before" do
    turns = Parse.parse("Anna: First line\nsecond line\nDaniel: Reply.\nAnna: Again.")
    assert_equal "First line\nsecond line", turns.first["t"]
  end

  test "structured turns, and what is refused" do
    turns = Parse.from_turns([ { speaker: "Anna", start_ms: 1500, text: "Hi" }, { "text" => "Unattributed." },
                               { speaker: "Daniel", start_ms: "00:03", text: "Hello" } ])
    assert_equal [ [ "Anna", 1500 ], [ nil, nil ], [ "Daniel", 3000 ] ], turns.map { |turn| [ turn["spk"], turn["s"] ] }

    assert_raises(Parse::Invalid) { Parse.parse("   ") }
    assert_raises(Parse::Invalid) { Parse.from_turns([]) }
    assert_raises(Parse::Invalid) { Parse.from_turns([ { speaker: "A", text: " " } ]) }
    assert_raises(Parse::Invalid) { Parse.from_turns([ { text: "x", start_ms: "soon" } ]) }
    assert_raises(Parse::Invalid) { Parse.from_turns([ { text: "x", start_ms: -5 } ]) }
    assert_raises(Parse::Invalid) { Parse.parse("x" * (Parse::MAX_CHARS + 1)) }
    many = (0..Parse::MAX_SPEAKERS).map { |n| { speaker: "Person #{n}", text: "hi" } }
    assert_raises(Parse::Invalid) { Parse.from_turns(many) }
  end

  test "rendering shows a time and a name only where they were given" do
    turns = [ { "spk" => nil, "s" => nil, "t" => "Header" }, { "spk" => "Anna", "s" => 65_000, "t" => "Hi" },
              { "spk" => "Daniel", "s" => nil, "t" => "Hello" } ]
    assert_equal "Header\n[01:05] Anya: Hi\nDaniel: Hello", Parse.render(turns, { "Anna" => "Anya" })
  end

end
