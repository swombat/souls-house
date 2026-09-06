module Api
  module V1
    class RuntimeEventsController < ActionController::API

      rate_limit to: 600, within: 1.minute, only: :create,
        by: -> { "#{request.remote_ip}:#{request.path_parameters[:run_id]}" },
        with: -> { response.set_header("Retry-After", "10"); head :too_many_requests }

      def create
        return head :payload_too_large if request.content_length.to_i > 64.kilobytes
        raw = request.body.read(64.kilobytes + 1)
        return head :payload_too_large if raw.bytesize > 64.kilobytes
        run = AgentRuntimeInteraction.find_by(run_id: request.path_parameters[:run_id])
        token = request.authorization.to_s.delete_prefix("Bearer ")
        return head :unauthorized unless run&.valid_activity_token?(token)

        render json: RuntimeActivityIngestion.new(run, JSON.parse(raw)).call
      rescue JSON::ParserError, RuntimeActivityIngestion::Invalid, ActiveRecord::RecordNotUnique
        render json: { error: "Invalid activity batch" }, status: :unprocessable_entity
      end

    end
  end
end
