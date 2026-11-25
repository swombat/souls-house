class Message::SpeechText

  MAX_LENGTH = 5_000

  def initialize(content)
    @text = content.to_s.dup
  end

  def to_s
    strip_code_blocks
    strip_inline_code
    strip_images
    strip_links
    strip_urls
    strip_stage_directions
    strip_markdown_formatting
    collapse_whitespace
    @text.strip.truncate(MAX_LENGTH)
  end

  private

  def strip_code_blocks
    @text.gsub!(/```[\s\S]*?```/, "I've included a code block here.")
  end

  def strip_inline_code
    @text.gsub!(/`([^`]+)`/) { $1 }
  end

  def strip_images
    @text.gsub!(/!\[[^\]]*\]\([^)]*\)/, "")
  end

  def strip_links
    @text.gsub!(/\[([^\]]*)\]\([^)]*\)/) { $1 }
  end

  def strip_urls
    @text.gsub!(%r{https?://\S+}, "")
  end

  def strip_stage_directions
    @text.gsub!(/^\s*\*[^*]+\*\s*$/m, "")
  end

  def strip_markdown_formatting
    @text.gsub!(/^\#{1,6}\s+/, "")              # headings
    @text.gsub!(/\*\*([^*]+)\*\*/) { $1 }   # bold
    @text.gsub!(/\*([^*]+)\*/) { $1 }       # italic
    @text.gsub!(/~~([^~]+)~~/) { $1 }       # strikethrough
    @text.gsub!(/^[ \t]*[-*+][ \t]+/, "")      # unordered list markers
    @text.gsub!(/^[ \t]*\d+\.[ \t]+/, "")      # ordered list markers
    @text.gsub!(/^>\s+/, "")                 # blockquotes
    @text.gsub!(/^---+$/, "")                # horizontal rules
  end

  def collapse_whitespace
    @text.gsub!(/\n{3,}/, "\n\n")
  end

end
