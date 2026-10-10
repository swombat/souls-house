module HouseInference
  class Request

    MAX_BYTES = 2.megabytes
    ALLOWED = %w[model messages tools tool_choice parallel_tool_calls temperature top_p stop seed frequency_penalty presence_penalty reasoning reasoning_effort include_reasoning response_format max_tokens max_completion_tokens stream stream_options].freeze

    def self.build(input, offering)
      raise Error.new('Unsupported request options.', status: 422) if (input.keys - ALLOWED).any?
      messages = input['messages']
      unless messages.is_a?(Array) && messages.present? && messages.size <= 4096
        raise Error.new('A bounded messages array is required.', status: 422)
      end
      # Byte count is deliberately conservative for this byte-tokenized model;
      # include per-message/tool framing instead of trusting a client token count.
      input_bound = JSON.generate(input).bytesize + messages.size * 32 + Array(input['tools']).size * 64 + 4096
      if input_bound > offering.fetch(:context_tokens)
        raise Error.new('House inference input exceeds the safe context limit. Compact the conversation first.', status: 422)
      end
      messages.each do |message|
        unless message.is_a?(Hash) && (message.keys - %w[role content name tool_calls tool_call_id reasoning reasoning_content reasoning_details refusal]).empty? && %w[system developer user assistant tool].include?(message['role'])
          raise Error.new('Invalid message.', status: 422)
        end
        content = message['content']
        next if content.nil? || content.is_a?(String)
        unless content.is_a?(Array) && content.all? { |part| part.is_a?(Hash) && part.keys.sort == %w[text type] && part['type'] == 'text' && part['text'].is_a?(String) }
          raise Error.new('House inference currently supports text and function tools only.', status: 422)
        end
      end
      tools = input['tools']
      if tools && (!tools.is_a?(Array) || tools.any? { |tool| !tool.is_a?(Hash) || tool['type'] != 'function' })
        raise Error.new('Only function tools are supported.', status: 422)
      end
      requested = input['max_completion_tokens'] || input['max_tokens'] || offering.fetch(:max_output_tokens)
      unless requested.is_a?(Integer) && requested.positive?
        raise Error.new('max_tokens must be a positive integer.', status: 422)
      end
      # parallel_tool_calls is accepted but never forwarded: with
      # require_parameters, OpenRouter finds no endpoint for either house
      # route when it is present (true or false), so every Chaos turn, which
      # always sends it, was refused with 404 (live check, 2026-10-10). Both
      # providers allow parallel tool calls by default.
      body = input.except('stream_options', 'max_completion_tokens', 'parallel_tool_calls').merge(
        'model' => offering.fetch(:upstream_model), 'stream' => input['stream'] == true,
        'max_tokens' => [ requested, offering.fetch(:max_output_tokens) ].min,
        'provider' => { 'only' => [ offering.fetch(:provider) ], 'allow_fallbacks' => false, 'require_parameters' => true,
          'max_price' => offering.fetch(:max_price), 'data_collection' => 'deny' },
        'usage' => { 'include' => true })
      body['stream_options'] = { 'include_usage' => true } if body['stream']
      body
    end

  end
end
