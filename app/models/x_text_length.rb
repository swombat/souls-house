# X's weighted post length: a port of twitter-text 3.1.0's parseTweet. The
# URL and emoji patterns are twitter-text's and twemoji-parser's own regexes,
# converted mechanically into config/x_text_patterns.json (see "source" there).
# test/models/x_text_length_test.rb checks this port against outputs taken
# from the official JavaScript library.
module XTextLength

  PATTERNS = JSON.parse(Rails.root.join("config/x_text_patterns.json").read).freeze
  CONFIG = PATTERNS.fetch("config").freeze
  MAX_WEIGHTED_LENGTH = CONFIG.fetch("maxWeightedTweetLength")
  URL_WEIGHT = CONFIG.fetch("transformedURLLength")
  SCALE = CONFIG.fetch("scale")
  DEFAULT_WEIGHT = CONFIG.fetch("defaultWeight")
  RANGES = CONFIG.fetch("ranges").map { |range| [ range["start"]..range["end"], range["weight"] ] }.freeze
  INVALID_CHARACTERS = /[\uFFFE\uFEFF\uFFFF]/
  MAX_URL_LENGTH = 4096
  MAX_TCO_SLUG_LENGTH = 40

  def self.compile(name)
    pattern = PATTERNS.fetch(name)
    options = pattern["ignore_case"] ? Regexp::IGNORECASE : 0
    verbose, $VERBOSE = $VERBOSE, nil # the generated classes repeat ranges
    Regexp.new(pattern.fetch("source"), options)
  ensure
    $VERBOSE = verbose
  end

  EXTRACT_URL = compile("extractUrl")
  INVALID_URL_WITHOUT_PROTOCOL_PRECEDING = compile("invalidUrlWithoutProtocolPrecedingChars")
  VALID_ASCII_DOMAIN = compile("validAsciiDomain")
  VALID_TCO_URL = compile("validTcoUrl")
  EMOJI = compile("emoji")

  module_function

  def weighted_length(text)
    parse(text)[:weighted_length]
  end

  def valid?(text)
    return false if text.to_s.strip.empty?

    parse(text)[:valid]
  end

  # twitter-text runs in UTF-16, where a character outside the BMP (most
  # emoji) is two code units, and its URL regexes see each half on its own.
  # To match its results exactly, URLs are found in a copy of the text where
  # every such character becomes two private-use placeholders, which fall in
  # the same regex classes a lone surrogate does. Offsets are in those units.
  HIGH_UNIT = "\uE000"
  LOW_UNIT = "\uE001"

  def parse(text)
    normalized = text.to_s.unicode_normalize(:nfc)
    units = +""
    unit_offsets = [] # code-point index -> unit index
    normalized.each_char do |char|
      unit_offsets << units.length
      units << (char.ord > 0xFFFF ? HIGH_UNIT + LOW_UNIT : char)
    end
    unit_offsets << units.length

    # parseTweet skips url.length units from a URL's start, and url.length is
    # not always the matched span (see url_entities), so keep both.
    urls = url_entities(units, normalized, unit_offsets).to_h { |start, _finish, advance| [ start, start + advance ] }
    emoji = emoji_entities(normalized).to_h { |start, finish| [ unit_offsets[start], unit_offsets[finish] ] }
    codepoint_at = unit_offsets.each_with_index.to_h { |unit, index| [ unit, normalized[index] ] }

    weighted = 0
    index = 0
    while index < units.length
      if (finish = urls[index])
        weighted += URL_WEIGHT * SCALE
        index = finish
      elsif (finish = emoji[index])
        weighted += DEFAULT_WEIGHT
        index = finish
      elsif (char = codepoint_at[index])
        weighted += character_weight(char.ord)
        index += char.ord > 0xFFFF ? 2 : 1
      else
        weighted += DEFAULT_WEIGHT # a lone half, as JS's charAt would see it
        index += 1
      end
    end

    length = weighted / SCALE
    { weighted_length: length, valid: length.positive? && length <= MAX_WEIGHTED_LENGTH && !normalized.match?(INVALID_CHARACTERS) }
  end

  def character_weight(codepoint)
    RANGES.each { |range, weight| return weight if range.cover?(codepoint) }
    DEFAULT_WEIGHT
  end

  # [start, end, length of the url string] in units, following
  # extractUrlsWithIndices.
  def url_entities(text, original = text, unit_offsets = nil)
    return [] unless text.include?(".")

    unit_offsets ||= (0..text.length).to_a

    entities = []
    position = 0
    while (match = EXTRACT_URL.match(text, position))
      position = match.end(0)
      before, url, protocol, domain, path = match[2], match[3], match[4], match[5], match[7]
      start = match.begin(3)
      finish = match.end(3)
      next unless (protocol.to_s.empty? ? "https://" : protocol).length + url.length <= MAX_URL_LENGTH
      next unless idna_valid?(domain, utf16_units(original, unit_offsets, match.begin(5), match.end(5)))

      if protocol.to_s.empty?
        next if before.to_s.match?(INVALID_URL_WITHOUT_PROTOCOL_PRECEDING)

        last = nil
        offset = 0
        domain.to_s.scan(VALID_ASCII_DOMAIN) do
          ascii = Regexp.last_match
          domain_start = domain.index(ascii[0], offset)
          offset = domain_start + ascii[0].length
          last = [ start + domain_start, start + offset, ascii[0].length ]
          entities << last
        end
        next unless last

        if path.present?
          # JS: lastUrl.url = url.replace(domain, asciiDomain), so its length
          # drops whatever non-ASCII part of the domain was left out.
          last[2] = url.length - domain.length + (last[1] - last[0])
          last[1] = finish
        end
      else
        if (tco = VALID_TCO_URL.match(url))
          next if tco[1] && tco[1].length > MAX_TCO_SLUG_LENGTH

          finish = start + tco[0].length
        end
        entities << [ start, finish, finish - start ]
      end
    end
    entities
  end

  # lib/idna.js toAscii: an xn-- domain must contain an ASCII domain, and
  # every label's punycode form must be 1..63 characters. Works on UTF-16
  # code units, as the JavaScript does.
  def idna_valid?(domain, units)
    return false if domain.start_with?("xn--") && !domain.match?(VALID_ASCII_DOMAIN)

    split_units(units, [ 0x2E ]).all? do |label|
      length = punycode_to_ascii_length(label)
      length >= 1 && length <= 63
    end
  end

  # The UTF-16 code units of original[unit start...unit finish).
  def utf16_units(original, unit_offsets, start, finish)
    units = []
    original.each_char.with_index do |char, index|
      first = unit_offsets[index]
      next if first + (char.ord > 0xFFFF ? 2 : 1) <= start || first >= finish

      if char.ord > 0xFFFF
        value = char.ord - 0x10000
        pair = [ 0xD800 + (value >> 10), 0xDC00 + (value & 0x3FF) ]
        units << pair[0] if first >= start
        units << pair[1] if first + 1 < finish
      else
        units << char.ord
      end
    end
    units
  end

  def split_units(units, separators)
    parts = [ [] ]
    units.each { |unit| separators.include?(unit) ? parts << [] : parts.last << unit }
    parts
  end

  # punycode 1.4.1 toASCII(label).length, on UTF-16 code units.
  def punycode_to_ascii_length(units)
    prefix = 0
    if (at = units.index(0x40))
      prefix = at + 1
      units = units[(at + 1)..]
    end
    labels = split_units(units, [ 0x2E, 0x3002, 0xFF0E, 0xFF61 ])
    prefix + labels.sum do |label|
      if label.any? { |unit| unit < 0x20 || unit > 0x7E }
        4 + punycode_encode_length(ucs2_decode(label))
      else
        label.length
      end
    end + labels.length - 1
  end

  def ucs2_decode(units)
    output = []
    index = 0
    while index < units.length
      value = units[index]
      index += 1
      if value.between?(0xD800, 0xDBFF) && index < units.length && units[index].between?(0xDC00, 0xDFFF)
        output << ((value - 0xD800) << 10) + (units[index] - 0xDC00) + 0x10000
        index += 1
      else
        output << value
      end
    end
    output
  end

  # Length of RFC 3492 punycode encoding (bootstring), as punycode.js encodes.
  def punycode_encode_length(codepoints)
    base, tmin, tmax, skew, damp = 36, 1, 26, 38, 700
    basic = codepoints.count { |codepoint| codepoint < 0x80 }
    length = basic + (basic.positive? ? 1 : 0)
    handled = basic
    n = 128
    delta = 0
    bias = 72
    adapt = lambda do |d, points, first|
      d = first ? d / damp : d / 2
      d += d / points
      k = 0
      while d > ((base - tmin) * tmax) / 2
        d /= base - tmin
        k += base
      end
      k + (((base - tmin + 1) * d) / (d + skew))
    end
    while handled < codepoints.length
      m = codepoints.select { |codepoint| codepoint >= n }.min
      delta += (m - n) * (handled + 1)
      n = m
      codepoints.each do |codepoint|
        delta += 1 if codepoint < n
        next unless codepoint == n

        q = delta
        k = base
        loop do
          t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
          break if q < t

          length += 1
          q = (q - t) / (base - t)
          k += base
        end
        length += 1
        bias = adapt.call(delta, handled + 1, handled == basic)
        delta = 0
        handled += 1
      end
      delta += 1
      n += 1
    end
    length
  end

  def emoji_entities(text)
    entities = []
    position = 0
    while (match = EMOJI.match(text, position))
      entities << [ match.begin(0), match.end(0) ]
      position = match.end(0)
    end
    entities
  end

end
