# Digits written out as words, for Phonon, which reads its text as written and
# says "2026" badly (the library's README: numbers read best written as
# words). Applied after the shared speech formatter (Message::SpeechText), on
# the Phonon path only: ElevenLabs normalises numbers itself.
#
# Covers what replies are made of: whole numbers with or without thousands
# commas, decimals, percentages, ordinals (1st, 22nd), times (18:57), years
# read as years (1999, 2026) and a leading minus. Anything longer than twelve
# digits is read digit by digit.
module SpeechNumbers

  ONES = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen
    fifteen sixteen seventeen eighteen nineteen].freeze
  TENS = %w[_ _ twenty thirty forty fifty sixty seventy eighty ninety].freeze
  SCALES = [ [ 1_000_000_000, "billion" ], [ 1_000_000, "million" ], [ 1_000, "thousand" ] ].freeze
  ORDINAL_WORDS = {
    "one" => "first", "two" => "second", "three" => "third", "five" => "fifth", "eight" => "eighth",
    "nine" => "ninth", "twelve" => "twelfth"
  }.freeze

  NUMBER = /(?<![\w.])(-?)(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(%|st|nd|rd|th)?(?![\w])/

  def self.spell(text)
    text.to_s
      .gsub(/(?<![\w:])([01]?\d|2[0-3]):([0-5]\d)(?![\w:])/) { time($1.to_i, $2.to_i) }
      .gsub(NUMBER) { number($1, $2, $3, $4) }
  end

  def self.number(minus, whole, fraction, suffix)
    digits = whole.delete(",")
    words =
      if digits.length > 12 then digits.chars.map { |d| ONES[d.to_i] }.join(" ")
      elsif fraction.nil? && suffix.nil? && !whole.include?(",") && year?(digits) then year(digits.to_i)
      else integer(digits.to_i)
      end
    words = ordinal(words) if %w[st nd rd th].include?(suffix)
    words += " point " + fraction.chars.map { |d| ONES[d.to_i] }.join(" ") if fraction
    words += " percent" if suffix == "%"
    minus == "-" ? "minus #{words}" : words
  end

  def self.integer(n)
    return ONES[n] if n < 20
    return TENS[n / 10] + (n % 10).positive?.then { |r| r ? "-#{ONES[n % 10]}" : "" } if n < 100
    return "#{ONES[n / 100]} hundred" + ((n % 100).positive? ? " and #{integer(n % 100)}" : "") if n < 1_000

    scale, name = SCALES.find { |size, _| n >= size }
    rest = n % scale
    joiner = rest.positive? && rest < 100 ? " and " : " "
    "#{integer(n / scale)} #{name}" + (rest.positive? ? "#{joiner}#{integer(rest)}" : "")
  end

  def self.year?(digits) = digits.length == 4 && digits.to_i.between?(1100, 2099)

  def self.year(n)
    return integer(n) if (n % 1000).zero? || (n / 100 % 10).zero? && n >= 2000

    high, low = n.divmod(100)
    low.zero? ? "#{integer(high)} hundred" : "#{integer(high)} #{low < 10 ? "oh #{ONES[low]}" : integer(low)}"
  end

  def self.time(hours, minutes)
    return "#{integer(hours)} o'clock" if minutes.zero?

    "#{integer(hours)} #{minutes < 10 ? "oh #{ONES[minutes]}" : integer(minutes)}"
  end

  def self.ordinal(words)
    *head, last = words.split(/([ -])/)
    last = ORDINAL_WORDS[last] || (last.end_with?("y") ? "#{last[0..-2]}ieth" : "#{last}th")
    [ *head, last ].join
  end

end
