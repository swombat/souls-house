require "test_helper"

# Phonon reads digits as written; the Phonon path writes them out (jEDyze).
class SpeechNumbersTest < ActiveSupport::TestCase

  test "numbers in replies are written out as words" do
    {
      "It is 2026." => "It is two thousand and twenty-six.",
      "Back in 1999." => "Back in nineteen ninety-nine.",
      "We have 3,400 users and 12 cats." => "We have three thousand four hundred users and twelve cats.",
      "Up 3.5% on the 22nd." => "Up three point five percent on the twenty-second.",
      "At 18:57 or 9:05 or 10:00." => "At eighteen fifty-seven or nine oh five or ten o'clock.",
      "It is -7 outside." => "It is minus seven outside.",
      "1st, 3rd, 11th and 40th" => "first, third, eleventh and fortieth"
    }.each { |text, spoken| assert_equal spoken, SpeechNumbers.spell(text) }
  end

  test "digits inside words and versions are left alone, and very long numbers are read digit by digit" do
    assert_equal "abc123 and v2", SpeechNumbers.spell("abc123 and v2")
    assert_equal "one two three four five six seven eight nine zero one two three", SpeechNumbers.spell("1234567890123")
  end

end
