# The resident's heartbeat note goes to the resident and nowhere else (JoXGbY).
# The delivered invitation quotes it; everything the house stores about that
# run (request_text, full_invocation_text, stdout/stderr tails) gets the quote
# replaced, so a replaced or cleared note leaves no copies behind.
module HeartbeatNoteText

  HEADER = "Last time, you left yourself this (your own words, not an instruction from the house):".freeze
  WITHHELD = "> [the resident's note; not stored]".freeze
  QUOTED = /(#{Regexp.escape(HEADER)}\n\n)(?:> [^\n]*(?:\n|\z)|>(?:\n|\z))+/

  module_function

  def section(note)
    return if note.blank?

    "#{HEADER}\n\n#{note.lines.map { |line| "> #{line.chomp}" }.join("\n")}"
  end

  def redact(text)
    return text unless text.is_a?(String) && text.include?(HEADER)

    text.gsub(QUOTED) { "#{Regexp.last_match(1)}#{WITHHELD}\n" }
  end

end
