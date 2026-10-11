require "test_helper"

class FieldRecording::LineCorrectionTest < ActiveSupport::TestCase

  W = ->(s, e, t, spk = "speaker_1", k = "w") { { "s" => s, "e" => e, "t" => t, "k" => k, "spk" => spk } }
  SP = ->(at, spk = "speaker_1") { { "s" => at, "e" => at, "t" => " ", "k" => "s", "spk" => spk } }

  def words
    [
      W.(0, 400, "Hi.", "speaker_0"),
      W.(3000, 3200, "I"), SP.(3200), W.(3300, 3500, "want"), SP.(3500), W.(3600, 3800, "it"), SP.(3800),
      W.(3900, 4100, "again,"), SP.(4100), W.(4200, 4600, "Dad.")
    ]
  end

  def correct(text, first: 1, last: 5, was: "I want it again, Dad.")
    FieldRecording::LineCorrection.replace_words(words, first:, last:, text:, was:)
  end

  def line(result) = result.drop(1).map { |word| word["t"] }.join

  test "one word changed keeps every timing and changes only that word" do
    result = correct("I want it again, Dan.")

    assert_equal "I want it again, Dan.", line(result)
    assert_equal words.map { |word| word.except("t") }, result.map { |word| word.except("t") }
    assert_equal "Hi.", result.first["t"], "other lines are untouched"
  end

  test "added words are spread over the time of the words they replace" do
    result = correct("I want it again, Daddy dear.")
    added = result.select { |word| %w[Daddy dear.].include?(word["t"]) }

    assert_equal "I want it again, Daddy dear.", line(result)
    assert_equal [ [ 4200, 4400 ], [ 4400, 4600 ] ], added.map { |word| [ word["s"], word["e"] ] }
    assert added.all? { |word| word["spk"] == "speaker_1" && word["k"] == "w" }
  end

  test "words can be removed, and a bracketed event stays one event" do
    result = correct("I want it (laughs) Dad.")

    assert_equal "I want it (laughs) Dad.", line(result)
    event = result.find { |word| word["t"] == "(laughs)" }
    assert_equal "a", event["k"]
    assert_equal [ 3900, 4100 ], [ event["s"], event["e"] ]
  end

  test "a line that no longer reads as it did is refused" do
    assert_raises(FieldRecording::LineCorrection::Stale) { correct("x", was: "I want it again, Dan.") }
    assert_raises(FieldRecording::LineCorrection::Stale) { correct("x", first: 1, last: 99) }
    assert_raises(FieldRecording::LineCorrection::Stale) { correct("x", first: "nope") }
  end

  test "the range must be exactly one displayed line" do
    assert_raises(FieldRecording::LineCorrection::Stale) { correct("x", first: 2, last: 5, was: "want it again, Dad.") }
    assert_raises(FieldRecording::LineCorrection::Stale) { correct("x", first: 0, last: 5, was: "Hi. I want it again, Dad.") }
    assert_equal [ [ 0, 0 ], [ 1, 5 ] ], FieldRecording::LineCorrection.turn_ranges(words)
  end

  test "a long line skips the word-by-word alignment and is retimed whole" do
    long = [ W.(0, 100_000, "word") ] + (1...600).flat_map { |n| [ SP.(n * 100), W.(n * 100, n * 100 + 50, "w#{n}") ] }
    long[0]["e"] = 50
    text = (0...600).map { |n| "x#{n}" }.join(" ")
    result = FieldRecording::LineCorrection.replace_words(long, first: 0, last: 599, text:, was: long.map { |w| w["t"] }.join)

    spoken = result.reject { |word| word["k"] == "s" }
    assert_equal 600, spoken.size
    assert_equal [ 0, 59_950 ], [ spoken.first["s"], spoken.last["e"] ]
  end

  test "an empty line is refused" do
    assert_raises(FieldRecording::LineCorrection::Invalid) { correct("   ") }
  end

  test "a supplied turn is replaced whole" do
    turns = [ { "spk" => "Anna", "s" => nil, "t" => "Hi Dad." }, { "spk" => "Dan", "s" => 1000, "t" => "Hi." } ]
    result = FieldRecording::LineCorrection.replace_turn(turns, index: "0", text: " Hi Dan. ", was: "Hi Dad.")

    assert_equal [ "Hi Dan.", "Hi." ], result.map { |turn| turn["t"] }
    assert_raises(FieldRecording::LineCorrection::Stale) do
      FieldRecording::LineCorrection.replace_turn(turns, index: 1, text: "x", was: "Hi Dad.")
    end
  end

end
