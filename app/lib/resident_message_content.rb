# Removes transport-only OpenAI citations, without inventing source links.
# This is deliberately not a Markdown parser: it protects top-level fenced
# blocks and matched inline backtick spans, not indented or nested code blocks.
module ResidentMessageContent

  CITATION = /\uE200cite(?:\uE202turn\d+[a-z]+\d+)+\uE201/
  INLINE_CODE = /(?<![`\\])(`+)(?!`).*?(?<!`)\1(?!`)/m

  def self.normalize(content)
    return content unless content.is_a?(String)

    result = +""
    prose = +""
    fence = nil

    content.each_line do |line|
      if fence
        result << line
        closing = line.match(/\A {0,3}(`+|~+)[ \t]*\r?\n?\z/)
        fence = nil if closing && closing[1][0] == fence[0] && closing[1].length >= fence.length
      elsif (opening = line.match(/\A {0,3}(`{3,}|~{3,})([^\r\n]*)/)) &&
          !(opening[1].start_with?("`") && opening[2].include?("`"))
        result << strip_prose(prose)
        prose.clear
        fence = opening[1]
        result << line
      else
        prose << line
      end
    end

    result << strip_prose(prose)
  end

  def self.strip_prose(prose)
    result = +""
    position = 0
    prose.to_enum(:scan, INLINE_CODE).each do
      span = Regexp.last_match
      result << prose[position...span.begin(0)].gsub(CITATION, "")
      result << span[0]
      position = span.end(0)
    end
    result << prose[position..].gsub(CITATION, "")
  end
  private_class_method :strip_prose

end
