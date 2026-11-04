module HouseInference
  # Why the house's upstream refused a call, in a form safe to keep on the
  # call row and show on the run (#725). Daniel's 31 Oct design stands:
  # never the raw body, never the request.
  #
  # Fail closed (Mira, PR #760 round 1): provider prose can quote the
  # resident's own content back, and no quote-stripping is a proof that it
  # didn't (escaped quotes, guillemets, unquoted echoes). So no provider text
  # is copied. The reason is built from parts the house can vouch for: an
  # identifier-shaped provider name, error code and type; a field path whose
  # named segments are all known request keys; and, when the message matches
  # a known diagnostic shape, the house's own sentence for it with only the
  # numbers carried over. Anything else is "detail withheld".
  #
  # OpenRouter wraps the provider's error: {"error": {"code", "message",
  # "metadata": {"provider_name", "raw"}}}, where raw is usually the
  # provider's own JSON ({"type":"error","error":{"type","message"}}).
  module RefusalReason

    MAX_BYTES = 64.kilobytes
    MAX_CHARS = 300
    WITHHELD = 'detail withheld'.freeze

    # Request keys a field path may name. Digits (array indexes) are also
    # allowed; the path stops at the first segment that is neither.
    PATH_KEYS = %w[
      messages system tools tool_choice max_tokens max_completion_tokens thinking budget_tokens temperature
      top_p top_k stop stop_sequences metadata model stream content text type role source image document
      tool_use tool_result tool_use_id input input_schema name description cache_control ttl reasoning
      effort response_format json_schema citations parameters function functions properties required
    ].freeze
    PATH_ROOTS = %w[
      messages system tools tool_choice max_tokens max_completion_tokens thinking temperature top_p top_k
      stop stop_sequences metadata model stream reasoning response_format
    ].freeze
    VALUE_KINDS = %w[string integer number boolean list array dict dictionary object].freeze

    # [pattern, house sentence]. The sentence may use only the captures,
    # and every capture is digits (or a VALUE_KINDS word, checked below).
    SHAPES = [
      [ /prompt is too long:\s*(\d+) tokens\s*>\s*(\d+)/i, 'prompt too long: %s tokens > %s maximum' ],
      [ /input length and `?max_tokens`? exceed context limit:\s*(\d+)\s*\+\s*(\d+)\s*>\s*(\d+)/i,
        'input %s + max_tokens %s exceeds the context limit %s' ],
      [ /maximum context length is (\d+) tokens.*?(?:requested|resulted in) (?:about )?(\d+)/im,
        'context too long: %2$s tokens requested, model maximum %1$s' ],
      [ /max_tokens:?\s*(\d+)\s*>\s*(\d+)/i, 'max_tokens %s above the model maximum %s' ],
      [ /maximum of (\d+) blocks with cache_control.*?Found (\d+)/im, 'too many cache_control blocks: %2$s > %1$s' ],
      [ /extra inputs are not permitted/i, 'field not accepted' ],
      [ /field required/i, 'required field missing' ],
      [ /input should be a valid (\w+)/i, 'invalid value, expected %s' ],
      [ /tool_use.{0,80}without.{0,40}tool_result/im, 'tool_use without a matching tool_result' ],
      [ /must have non-empty content/i, 'empty message content' ],
      [ /roles must alternate/i, 'message roles must alternate' ],
      [ /no endpoints found/i, 'no provider endpoint accepts this request' ],
      [ /assistant message prefill/i, 'the request ends with an assistant message, which this model refuses (no prefill)' ],
      [ /(?:does not support|not supported|unsupported)/i, 'not supported by this model or route' ],
      [ /context (?:length|window)/i, 'context too long' ]
    ].freeze

    module_function

    def call(body)
      text = body.to_s.byteslice(0, MAX_BYTES).to_s.scrub('')
      return if text.strip.empty?

      envelope = parse(text)
      return finish("unreadable body (#{text.bytesize} bytes)") unless envelope.is_a?(Hash)

      error = envelope['error']
      return finish('no error field') unless error.is_a?(Hash)

      metadata = error['metadata'].is_a?(Hash) ? error['metadata'] : {}
      raw = metadata['raw']
      raw = parse(raw) || raw if raw.is_a?(String)
      inner = raw.is_a?(Hash) && raw['error'].is_a?(Hash) ? raw['error'] : nil

      head = [ word(metadata['provider_name']), word(error['code']) && "code #{word(error['code'])}",
        word(inner&.dig('type')) || word(inner&.dig('code')) || word(error['type']) ].compact.join(' ')
      message = [ inner&.dig('message'), raw.is_a?(String) ? raw : nil, error['message'] ].find { |m| m.is_a?(String) }
      finish([ head.presence, detail(message) ].compact.join(': '))
    end

    def detail(message)
      return WITHHELD unless message.is_a?(String)

      [ path(message), shape(message) || WITHHELD ].compact.join(': ')
    end

    # A leading "a.b.0.c:" field path, kept up to its first unknown segment.
    def path(message)
      match = message.match(/\A\s*([A-Za-z_]\w*(?:\.\w+)*)\s*:/)
      return unless match

      segments = match[1].split('.')
      return unless PATH_ROOTS.include?(segments.first)

      kept = segments.take_while { |segment| segment.match?(/\A\d{1,6}\z/) || PATH_KEYS.include?(segment) }
      kept.join('.') + (kept.length < segments.length ? '.…' : '')
    end

    def shape(message)
      SHAPES.each do |pattern, sentence|
        match = message.match(pattern)
        next unless match

        captures = match.captures
        next unless captures.all? { |c| c.match?(/\A\d{1,9}\z/) || VALUE_KINDS.include?(c.downcase) }

        return format(sentence, *captures.map(&:downcase))
      end
      nil
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
      value if value.match?(/\A[A-Za-z0-9][\w.\-]{0,39}\z/)
    end

    def finish(text)
      text = text.to_s.squish
      text.presence && text.truncate(MAX_CHARS)
    end

  end
end
