module HouseInference
  # Why the house's upstream refused a call, in a form safe to keep on the
  # call row and show on the run (#725). Daniel's 31 Oct design stands:
  # never the raw body, never the request. A provider's 400 message can
  # quote the resident's own content back (`messages.3.content.0.text:
  # "…"`), so only the shape is kept: the provider's name, the error type or
  # code, and the message with everything inside quotes removed, capped.
  #
  # OpenRouter wraps the provider's error: {"error": {"code", "message",
  # "metadata": {"provider_name", "raw"}}}, where raw is usually the
  # provider's own JSON ({"type":"error","error":{"type","message"}}).
  module RefusalReason

    MAX_BYTES = 64.kilobytes
    MAX_CHARS = 300
    # A quoted span, closed or running to the end of the text. Double quotes,
    # curly quotes and backticks always quote; a single quote only when it
    # opens after a non-word character, so an apostrophe ("model's") stays.
    QUOTED = /"(?:[^"\\]|\\.)*(?:"|\z)|“[^”]*(?:”|\z)|‘[^’]*(?:’|\z)|`[^`]*(?:`|\z)|(?<![\p{L}\p{N}])'[^']*(?:'|\z)/m

    module_function

    def call(body)
      text = body.to_s.byteslice(0, MAX_BYTES).to_s.scrub('')
      return if text.strip.empty?

      envelope = parse(text)
      return finish("unreadable body (#{text.bytesize} bytes)") unless envelope.is_a?(Hash)

      error = envelope['error']
      return finish('no error field') unless error.is_a?(Hash)

      metadata = error['metadata'].is_a?(Hash) ? error['metadata'] : {}
      provider = word(metadata['provider_name'])
      raw = metadata['raw']
      raw = parse(raw) || raw if raw.is_a?(String)
      inner = raw.is_a?(Hash) && raw['error'].is_a?(Hash) ? raw['error'] : nil

      kind = word(inner&.dig('type')) || word(inner&.dig('code')) || word(error['type'])
      message = inner&.dig('message') || (raw.is_a?(String) ? raw : nil) || error['message']
      parts = []
      parts << provider if provider
      parts << "code #{word(error['code'])}" if word(error['code'])
      parts << kind if kind
      head = parts.join(' ')
      detail = strip(message)
      finish([ head.presence, detail.presence ].compact.join(': '))
    end

    def parse(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    # A short identifier (a provider name, an error type or code), or nil.
    def word(value)
      value = value.to_s if value.is_a?(Integer)
      return unless value.is_a?(String)

      value = value.strip
      value if value.match?(/\A[\w .\-\/]{1,60}\z/)
    end

    def strip(message)
      return '' unless message.is_a?(String)

      message.gsub(QUOTED, '[…]').gsub(/[[:cntrl:]]+/, ' ').squish
    end

    def finish(text)
      text = text.to_s.squish
      text.presence && text.truncate(MAX_CHARS)
    end

  end
end
