# Correcting one line of a transcript by hand: "she said Dan, not Dad". A
# line is what the page shows as one turn. The person sends the line's new
# text with the text it replaces and the transcript's revision they saw
# (FieldRecording#transcript_revision); the change is refused if anything in
# the transcript has changed since, since a shift elsewhere can move a line's
# word positions onto another line that reads the same.
#
# Timed words keep their timings wherever they survive the edit: the old and
# new lines are aligned word by word, and only the words that changed are
# replaced. Each replaced run is spread evenly over the time its old words
# took, so highlighting while playing stays close.
module FieldRecording::LineCorrection

  class Stale < StandardError; end
  class Invalid < StandardError; end

  MAX_CHARS = 10_000
  # Past this many cells the word-by-word alignment isn't worth its table: the
  # whole line is retimed over its span instead.
  MAX_ALIGN_CELLS = 250_000
  # A bracketed event is one token, as Scribe gives it: "(soft laughter)".
  TOKEN = /\([^)]*\)|\[[^\]]*\]|\S+/
  EVENT = /\A(?:\(.*\)|\[.*\])\z/m

  module_function

  # `words` are the stored entries ({s, e, t, k, spk}). `first` and `last`
  # are positions among the entries that are not spacing (the page's `i`).
  # Returns the new list; the original is not changed.
  def replace_words(words, first:, last:, text:, was:)
    first = Integer(first, exception: false)
    last = Integer(last, exception: false)
    timed = words.each_index.reject { |n| words[n]["k"] == "s" }
    raise Stale unless first && last && first >= 0 && first <= last && last < timed.size

    raise Stale unless turn_ranges(words).include?([ first, last ])

    from = timed[first]
    to = timed[last]
    span = words[from..to]
    raise Stale unless normalise(span.map { |word| word["t"] }.join) == normalise(was)

    old = span.reject { |word| word["k"] == "s" }
    tokens = tokens!(text)
    replaced = realign(old, tokens)
    words[0...from] + with_spacing(replaced, kept_spacing(span)) + words[(to + 1)..]
  end

  # The spacing that followed each old word: a kept word keeps the spacing
  # after it, whatever now follows.
  def kept_spacing(span)
    gaps = {}.compare_by_identity
    word = nil
    between = []
    span.each do |entry|
      if entry["k"] == "s"
        between << entry
      else
        gaps[word] = between if word
        word = entry
        between = []
      end
    end
    gaps
  end

  # [first, last] timed-word positions of each displayed turn, grouped as
  # FieldRecording::Transcript.turns and the page's buildTurns group them.
  def turn_ranges(words)
    ranges = []
    spk = nil
    finish = nil
    position = -1
    words.each do |word|
      next if word["k"] == "s"

      position += 1
      start = word["s"].to_i
      if ranges.any? && word["spk"] == spk && start - finish <= FieldRecording::Transcript::TURN_GAP_MS
        ranges.last[1] = position
        finish = [ finish, (word["e"] || start).to_i ].max
      else
        ranges << [ position, position ]
        spk = word["spk"]
        finish = (word["e"] || start).to_i
      end
    end
    ranges
  end

  # Supplied transcripts have turns ({spk, s, t}), one line each.
  def replace_turn(turns, index:, text:, was:)
    index = Integer(index, exception: false)
    raise Stale unless index && index >= 0 && index < turns.size
    raise Stale unless normalise(turns[index]["t"]) == normalise(was)

    text = text.to_s.gsub(/\r\n?/, "\n").strip
    raise Invalid, "A line can't be empty." if text.empty?
    raise Invalid, "That line is too long." if text.length > MAX_CHARS

    turns.each_with_index.map { |turn, n| n == index ? turn.merge("t" => text) : turn }
  end

  def tokens!(text)
    text = text.to_s
    raise Invalid, "That line is too long." if text.length > MAX_CHARS

    tokens = text.scan(TOKEN)
    raise Invalid, "A line can't be empty." if tokens.empty?

    tokens
  end

  def normalise(text) = text.to_s.gsub(/\s+/, " ").strip

  # Words in common (by longest common subsequence) are kept as they are;
  # between two kept words, the old words that went and the new words that
  # came form one run, retimed over the old run's span.
  def realign(old, tokens)
    spk = old.first["spk"]
    return retime(tokens, old, before: nil, after: nil, spk:) if old.size * tokens.size > MAX_ALIGN_CELLS

    pairs = common(old.map { |word| word["t"] }, tokens)
    result = []
    old_at = 0
    new_at = 0
    (pairs + [ [ old.size, tokens.size ] ]).each do |old_match, new_match|
      gone = old[old_at...old_match]
      came = tokens[new_at...new_match]
      result.concat(retime(came, gone, before: result.last, after: old[old_match], spk:)) if came.any?
      result << old[old_match] if old_match < old.size
      old_at = old_match + 1
      new_at = new_match + 1
    end
    result
  end

  def common(a, b)
    table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
    (a.size - 1).downto(0) do |i|
      (b.size - 1).downto(0) do |j|
        table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : [ table[i + 1][j], table[i][j + 1] ].max
      end
    end
    pairs = []
    i = j = 0
    while i < a.size && j < b.size
      if a[i] == b[j]
        pairs << [ i, j ]
        i += 1
        j += 1
      elsif table[i + 1][j] >= table[i][j + 1]
        i += 1
      else
        j += 1
      end
    end
    pairs
  end

  def retime(came, gone, before:, after:, spk:)
    if gone.any?
      start = gone.first["s"]
      finish = gone.map { |word| word["e"] || word["s"] }.max
    else
      start = before ? (before["e"] || before["s"]) : after["s"]
      finish = after ? after["s"] : start
    end
    finish = [ finish, start ].max
    step = (finish - start).fdiv(came.size)
    came.each_with_index.map do |token, n|
      {
        "s" => (start + step * n).round, "e" => (start + step * (n + 1)).round, "t" => token,
        "k" => token.match?(EVENT) ? "a" : "w", "spk" => spk
      }
    end
  end

  def with_spacing(entries, gaps = {})
    entries.each_with_index.flat_map do |entry, n|
      next [ entry ] if n.zero?

      previous = entries[n - 1]
      gap = gaps[previous]
      next [ *gap, entry ] if gap&.any?

      at = previous["e"] || previous["s"]
      [ { "s" => at, "e" => [ entry["s"], at ].max, "t" => " ", "k" => "s", "spk" => entry["spk"] }, entry ]
    end
  end

end
