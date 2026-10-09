# A transcript that arrives with the audio instead of from the transcriber:
# the archive of transcripts written before the Field existed. It may have
# speakers and times, or neither, and never has word timings, so it is kept as
# turns ({spk, s, t}; s in ms or nil) and never dressed up as timed words.
module FieldRecording::SuppliedTranscript

  class Invalid < StandardError; end

  MAX_CHARS = 1_000_000
  MAX_LABEL_LENGTH = 60
  # Higher than Scribe's 32, which bounds what the diarizer is asked for: a
  # supplied transcript says who spoke, and the archive has a 33-voice one.
  MAX_SPEAKERS = 100
  # "[01:02:03] Name: words", "00:12 Name: words", "Name: words". A label is
  # short and has no sentence punctuation, so "So: what now" is caught but
  # "Then he said: no" is not (it fails the word-count cap below).
  TIMESTAMP = /\[?(?<ts>(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d+)?)\]?/
  LINE = /\A\s*(?:#{TIMESTAMP}\s*[-–—]?\s*)?(?<label>[^\s:\[\]][^:\[\]\n]{0,#{MAX_LABEL_LENGTH - 1}}?)\s*:\s+(?<text>\S.*)\z/
  TIMED_ONLY = /\A\s*#{TIMESTAMP}\s*[-–—]?\s*(?<text>\S.*)\z/m
  TIME_ALONE = /\A\s*#{TIMESTAMP}\s*\z/
  # Keys that open the archive's metadata blocks; a label from this list is
  # metadata even alone on its line. Anything else needs the block shape.
  METADATA_KEYS = %w[source sources date title id tab speakers attendees participants duration recorded location
                     corrected file audio transcript transcribed language].freeze
  TIMESTAMP_START = /\A\s*#{TIMESTAMP}\s/
  # "**Name**:", "**Date:**", "**[00:04] speaker_0:**" and "[00:04] **Name**:".
  UNBOLD = /\A(?<pre>\s*(?:#{TIMESTAMP}\s*)?)(?<mark>\*\*|__)(?<label>[^\n]{1,#{MAX_LABEL_LENGTH + 20}}?)\k<mark>/
  MAX_LABEL_WORDS = 4

  module_function

  # From the API's structured form: [{speaker:, start_ms:, text:}].
  def from_turns(entries)
    raise Invalid, "transcript_turns must be a list" unless entries.is_a?(Array)
    raise Invalid, "transcript_turns is empty" if entries.empty?

    turns = entries.map do |entry|
      raise Invalid, "each turn must be an object" unless entry.respond_to?(:to_h)

      entry = entry.to_h.stringify_keys
      text = entry["text"].to_s.strip
      raise Invalid, "each turn needs text" if text.empty?

      { "spk" => label(entry["speaker"]), "s" => start_ms(entry["start_ms"]), "t" => text }
    end
    check!(turns)
  end

  # From plain text, in the shapes the archive has: "**Speaker A**: words",
  # "[00:04] speaker_0: words", "00:00 Daniel: words", Google Meet notes (a
  # time on its own line, turns separated by vertical tabs), or prose.
  #
  # Speaker mode needs some label to occur at least twice, so prose with one
  # "Note:" stays prose. Leading paragraphs that look like metadata (see
  # header_paragraph?) are kept, verbatim, as one unattributed turn. Nothing
  # is ever dropped: unlabelled lines continue the turn before, or start an
  # unattributed one; a time alone on a line dates the next turn.
  def parse(text)
    text = text.to_s.gsub(/\r\n?|\v/, "\n").strip
    raise Invalid, "The transcript is empty." if text.empty?
    raise Invalid, "The transcript is longer than #{MAX_CHARS} characters." if text.length > MAX_CHARS

    lines = text.split("\n").map { |line| unbold(line) }
    counts = lines.filter_map { |line| labelled_line(line)&.[](:label)&.squish }.tally
    turns = counts.values.any? { |count| count >= 2 } ? speaker_turns(lines, counts) : paragraph_turns(lines)
    check!(turns)
  end

  # "[mm:ss] Name: text" where a time and a name were given; just the text
  # otherwise. Names come from the caller, keyed by label.
  def render(turns, names)
    Array(turns).map do |turn|
      prefix = turn["s"] ? "[#{FieldRecording::Transcript.timestamp(turn['s'])}] " : ""
      speaker = turn["spk"] ? "#{names.fetch(turn['spk'], turn['spk'])}: " : ""
      "#{prefix}#{speaker}#{turn['t']}"
    end.join("\n")
  end

  # [{label:, position:}] in order of first appearance. No talk time and no
  # clip: without word timings neither can be known.
  def speakers(turns)
    turns.filter_map { |turn| turn["spk"] }.uniq.each_with_index.map { |label, position| { label:, position: } }
  end

  def labelled_line(line)
    match = LINE.match(line)
    return nil unless match
    return nil if match[:label].split.size > MAX_LABEL_WORDS || match[:label].match?(/[.!?]\z/)
    # Markdown notes, not people: "- Goal:", "### Vision:", "3. **Fraud**:".
    return nil if match[:label].match?(/\A(?:[-*+#>]|\d+[.)]\s)/)

    match
  end

  def speaker_turns(lines, counts)
    paragraphs = lines.chunk { |line| line.strip.empty? ? :_separator : true }.map(&:last)
    header = []
    header.concat(paragraphs.shift) while paragraphs.any? && paragraphs.size > 1 && header_paragraph?(paragraphs.first, counts)

    turns = []
    pending_ms = nil
    paragraphs.flatten.each do |line|
      if (alone = TIME_ALONE.match(line))
        pending_ms = start_ms(alone[:ts])
      elsif (match = labelled_line(line))
        turns << { "spk" => label(match[:label]), "s" => start_ms(match[:ts]) || pending_ms, "t" => match[:text].strip }
        pending_ms = nil
      elsif turns.any? && pending_ms.nil?
        turns.last["t"] = "#{turns.last['t']}\n#{line.strip}"
      else
        turns << { "spk" => nil, "s" => pending_ms, "t" => line.strip }
        pending_ms = nil
      end
    end

    header.any? ? [ { "spk" => nil, "s" => nil, "t" => header.map(&:strip).join("\n") }, *turns ] : turns
  end

  # A paragraph is metadata, not speech, only when all of these hold: it
  # carries no time (a timed line is speech, and a time alone dates speech);
  # none of its labels recurs anywhere in the transcript; and it looks like a
  # block, not one utterance: two or more lines, a markdown heading or rule,
  # or metadata keys ("Source:", "Date:").
  # So "Source: ...\nSpeakers: ..." is a header, and a speaker who opens with
  # one untimed line in its own paragraph stays a speaker.
  def header_paragraph?(paragraph, counts)
    return false if paragraph.any? { |line| TIME_ALONE.match?(line) || labelled_line(line)&.[](:ts) || TIMESTAMP_START.match?(line) }
    return false if paragraph.any? { |line| (match = labelled_line(line)) && counts[match[:label].squish] >= 2 }

    paragraph.size >= 2 || paragraph.any? { |line| line.match?(/\A\s*(#|---|===)/) } ||
      paragraph.all? { |line| METADATA_KEYS.include?(labelled_line(line)&.[](:label)&.squish&.downcase) }
  end

  # "**Speaker A**: words" and "**Date:** 2026-03-25" read as plain labels.
  def unbold(line)
    line.sub(UNBOLD) { "#{Regexp.last_match[:pre]}#{Regexp.last_match[:label]}" }
  end

  def paragraph_turns(lines)
    lines.join("\n").split(/\n\s*\n/).filter_map do |paragraph|
      paragraph = paragraph.strip
      next if paragraph.empty?

      match = TIMED_ONLY.match(paragraph)
      if match
        { "spk" => nil, "s" => start_ms(match[:ts]), "t" => match[:text].strip }
      else
        { "spk" => nil, "s" => nil, "t" => paragraph }
      end
    end
  end

  def label(value)
    value = value.to_s.squish
    return nil if value.empty?
    raise Invalid, "A speaker name is longer than #{MAX_LABEL_LENGTH} characters." if value.length > MAX_LABEL_LENGTH

    value
  end

  # "01:02:03", "02:03", "02:03.5" or an integer of ms. nil when absent.
  def start_ms(value)
    return nil if value.nil? || value.to_s.strip.empty?
    return value if value.is_a?(Integer) && value >= 0

    parts = value.to_s.strip.tr(",", ".").split(":")
    raise Invalid, "A start time can't be read: #{value.to_s.truncate(20)}" unless parts.size.between?(2, 3) &&
      parts[0..-2].all? { |part| part.match?(/\A\d{1,2}\z/) } && parts.last.match?(/\A\d{1,2}(\.\d+)?\z/)

    seconds = parts.map(&:to_f).reverse.each_with_index.sum { |part, index| part * (60**index) }
    (seconds * 1000).round
  end

  def check!(turns)
    raise Invalid, "The transcript is empty." if turns.empty?
    raise Invalid, "The transcript is longer than #{MAX_CHARS} characters." if turns.sum { |turn| turn["t"].length } > MAX_CHARS
    if speakers(turns).size > MAX_SPEAKERS
      raise Invalid, "The transcript names more than #{MAX_SPEAKERS} speakers."
    end

    turns
  end

end
