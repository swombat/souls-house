require 'net/http'

module HouseInference
  class Gateway

    URL = URI('https://openrouter.ai/api/v1/chat/completions')

    def initialize(agent:, input:)
      @agent, @input = agent, input
    end

    def call
      offering = Offering.find(@input['model'])
      unless offering && @agent.model_id == @input['model']
        raise Error.new('Only the resident’s selected house model is allowed.', status: 403)
      end
      raise Error.new('House inference has not been configured by the operator.') unless Offering.configured?
      grant = HouseInferenceGrant.find_by(agent: @agent)
      raise Error.new('This resident has no house allowance.', status: 403) unless grant
      body = Request.build(@input, offering)
      call = grant.reserve!(offering, @input['model'], agent_id: @agent.id)
      buffer = +''
      usage = nil
      upstream_id = nil
      completed = false
      streaming = @input['stream'] == true
      total_bytes = 0
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
      request = Net::HTTP::Post.new(URL)
      request['Authorization'] = "Bearer #{Offering.key}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)
      http = Net::HTTP.new(URL.host, URL.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 120
      http.write_timeout = 30
      http.max_retries = 0
      # A retry is a new admitted call, never a hidden repeat of a billed POST.
      http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          # Only OpenRouter's own routing refusal is known to be unbilled: a 404
          # saying no endpoint can serve the request, decided before any
          # provider sees it (live check, 2026-10-10). It releases the
          # reservation. Every other failure, including timeouts and other 4xx,
          # keeps the conservative charge for reconciliation.
          call.settle!({ 'cost' => 0 }) if self.class.routing_refusal?(response, deadline: deadline)
          raise Error.new('The pinned house provider could not complete this request. No personal credentials were used.', status: 502)
        end
        response.read_body do |chunk|
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise Error.new('The house provider exceeded the call time limit.', status: 502)
          end
          total_bytes += chunk.bytesize
          raise Error.new('Provider response exceeded the safety limit.', status: 502) if total_bytes > 8.megabytes
          buffer << chunk
          next unless streaming
          while (line = buffer.slice!(/\A.*?\n/m))
            next unless line.start_with?('data:')
            data = line.delete_prefix('data:').strip
            if data == '[DONE]'
              completed = true
              next
            end
            event = JSON.parse(data)
            raise Error.new('The house provider returned an invalid stream event.', status: 502) unless event.is_a?(Hash)
            raise Error.new('The house provider interrupted this response.', status: 502) if event['error']
            upstream_id ||= event['id']
            usage = event['usage'] if event['usage'].is_a?(Hash)
            event['model'] = @input['model'] if event.key?('model')
            yield "data: #{JSON.generate(event)}\n\n"
          end
        end
      end
      unless streaming
        result = JSON.parse(buffer)
        unless result.is_a?(Hash) && result['choices'].is_a?(Array) && !result['error']
          raise Error.new('The house provider returned an invalid completion.', status: 502)
        end
        usage, upstream_id = result['usage'], result['id']
        result['model'] = @input['model']
        completed = true
      end
      raise Error.new('The house provider response ended unexpectedly.', status: 502) unless completed
      call.settle!(usage, upstream_id: upstream_id)
      yield "data: [DONE]\n\n" if streaming
      result
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error
      # Do not log upstream bodies, requests, credentials or exception messages.
      raise Error.new('House inference was interrupted. The call’s safety charge is retained pending reconciliation.', status: 502)
    ensure
      call&.settle!(nil, upstream_id: upstream_id)
    end

    ROUTING_REFUSAL = /\ANo endpoints found that (?:can handle|support) the requested parameters/
    REFUSAL_BODY_LIMIT = 16.kilobytes
    # Bounded in bytes and by the call's absolute deadline: the refusal body is
    # a small JSON error, never a completion. Anything else, including valid
    # JSON of another shape, is not a refusal.
    def self.routing_refusal?(response, deadline:)
      return false unless response.code == '404'
      body = +''
      response.read_body do |chunk|
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        body << chunk
        return false if body.bytesize > REFUSAL_BODY_LIMIT
      end
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      parsed = JSON.parse(body)
      error = parsed['error'] if parsed.is_a?(Hash)
      message = error['message'] if error.is_a?(Hash)
      message.is_a?(String) && ROUTING_REFUSAL.match?(message)
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error
      false
    end

  end
end
