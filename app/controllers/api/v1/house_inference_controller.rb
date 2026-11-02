module Api
  module V1
    class HouseInferenceController < BaseController

      include ActionController::Live

      def models
        return head :forbidden unless current_api_agent
        model = current_api_agent.model_id
        offering = HouseInference::Offering.find(model)
        render json: { object: 'list', data: offering ? [
          { id: model, object: 'model', owned_by: 'house', context_length: offering.fetch(:context_tokens) }
        ] : [] }
      end

      def create
        return head :forbidden unless current_api_agent
        raw = request.body.read(HouseInference::Request::MAX_BYTES + 1)
        if raw.bytesize > HouseInference::Request::MAX_BYTES
          return render json: { error: { message: 'Request too large.' } }, status: :content_too_large
        end
        input = JSON.parse(raw)
        unless input.is_a?(Hash) && [ true, false, nil ].include?(input['stream'])
          return render json: { error: { message: 'Invalid chat completion request.' } }, status: :unprocessable_entity
        end
        response.headers['Content-Type'] = 'text/event-stream' if input['stream']
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Last-Modified'] = Time.current.httpdate # bypass Rack::ETag buffering
        response.headers['X-Accel-Buffering'] = 'no'
        result = HouseInference::Gateway.new(agent: current_api_agent, input: input).call do |chunk|
          response.stream.write(chunk)
        end
        render json: result unless input['stream']
      rescue JSON::ParserError
        render json: { error: { message: 'Invalid JSON.' } }, status: :bad_request
      rescue HouseInference::Error => e
        record_refusal(e)
        payload = { error: { message: e.message, code: e.code } }
        if response.committed?
          response.stream.write("data: #{JSON.generate(payload)}\n\n")
        else
          render json: payload, status: e.status, content_type: 'application/json'
        end
      rescue ActionController::Live::ClientDisconnected, IOError
        # Gateway ensure retains the charge when a client abandons a live call.
      rescue StandardError => e
        Rails.logger.error("House inference failed (#{e.class.name})")
        payload = { error: { message: "House inference could not complete this request.", code: "house_inference_unavailable" } }
        if response.committed?
          response.stream.write("data: #{JSON.generate(payload)}\n\n")
        else
          render json: payload, status: :service_unavailable, content_type: "application/json"
        end
      ensure
        response.stream.close
      end

      private

      # A refused call says why on the run that made it (#678), so the owner
      # reads "allowance used up" instead of a generic runtime error. Only
      # the run named in X-Soulshouse-Run, only if it is this resident's and
      # still running: concurrent runs of one resident never borrow each
      # other's refusal, and a header naming another resident's run, a
      # finished run or nothing at all records nothing.
      def record_refusal(error)
        return unless error.code.in?(AgentRuntimeInteraction::FailureReport::INFERENCE_REFUSALS)

        run_id = request.headers['X-Soulshouse-Run'].to_s
        return unless run_id.match?(/\A\d{1,18}\z/)

        current_api_agent.agent_runtime_interactions.where(id: run_id, finished_at: nil)
          .update_all(inference_refusal: error.code)
      rescue StandardError => e
        Rails.logger.warn("House inference refusal not recorded (#{e.class.name})")
      end

    end
  end
end
