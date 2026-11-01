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
      body = Request.build(@input, offering)
      call = reserve!(offering)
      buffer = +''
      usage = nil
      upstream_id = nil
      generated = false
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
          # A refused request delivered nothing, so the resident pays nothing
          # for it, whatever the status (Daniel, JwMQEe, 2026-10-31). If the
          # provider billed the house anyway, that is the house's cost. The
          # status is kept (never the body) so refusals can be told apart.
          call.release!(http_status: response.code.to_i)
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
            generated ||= self.class.generated?(event)
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
        generated = self.class.generated?(result)
        result['model'] = @input['model']
        completed = true
      end
      raise Error.new('The house provider response ended unexpectedly.', status: 502) unless completed
      call.settle!(usage, upstream_id: upstream_id)
      yield "data: [DONE]\n\n" if streaming
      result
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error
      # Do not log upstream bodies, requests, credentials or exception messages.
      raise Error.new('House inference was interrupted.', status: 502)
    ensure
      # Nothing generated (no text, tool call or reasoning; an id or a
      # role-only frame alone is not output): the resident pays nothing,
      # unless the provider reported a known cost. Usage without a cost
      # (empty, or token counts only) doesn't count. Once output arrived, a
      # known cost settles; otherwise the conservative charge stays for
      # reconciliation. The id is kept either way.
      if generated || (usage.is_a?(Hash) && !HouseInference::UsageCost.call(usage).first.nil?)
        call&.settle!(usage, upstream_id: upstream_id)
      else
        call&.release!(upstream_id: upstream_id)
      end
    end

    # Whether a stream event or completion carries model output.
    def self.generated?(payload)
      choices = payload['choices']
      return false unless choices.is_a?(Array)
      choices.any? do |choice|
        next false unless choice.is_a?(Hash)
        part = choice['delta'] || choice['message']
        next false unless part.is_a?(Hash)
        %w[content reasoning].any? { |key| part[key].is_a?(String) && !part[key].empty? } ||
          %w[tool_calls reasoning_details].any? { |key| part[key].is_a?(Array) && part[key].any? }
      end
    end

    private

    # A paid plan's allowance first (paid replaces the free grant, never
    # stacks); otherwise the user's free grant. Each ledger re-checks under
    # the lock, so a plan that lapses in between is refused, not misbilled.
    def reserve!(offering)
      entitlement = ResidentEntitlement.find_by(agent: @agent)
      return entitlement.reserve_house_call!(offering, @input['model'], agent_id: @agent.id) if entitlement&.funds_calls?
      # Asleep: its plan lapsed. The free grant doesn't stand in for it.
      raise Error.new('This resident is asleep: the payment for its plan has lapsed.', status: 403) if entitlement&.held?

      grant = HouseInferenceGrant.find_by(agent: @agent)
      raise Error.new('This resident has no house allowance.', status: 403) unless grant
      grant.reserve!(offering, @input['model'], agent_id: @agent.id)
    end

  end
end
