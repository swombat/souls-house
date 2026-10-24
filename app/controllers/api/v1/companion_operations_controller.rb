module Api
  module V1
    class CompanionOperationsController < BaseController

      before_action :require_resident
      before_action :find_device

      def create
        arguments = params[:arguments]
        return render json: { error: "arguments must be an object" }, status: :unprocessable_entity unless
          arguments.nil? || arguments.is_a?(ActionController::Parameters)

        operation = CompanionOperation.start!(device: @device, agent: current_api_agent,
          kind: params[:operation].to_s, arguments: arguments&.to_unsafe_h || {})
        operation.dispatch!
        render json: presented(operation), status: :accepted
      rescue CompanionOperation::Refused => error
        render json: { error: error.message }, status: :conflict
      end

      def show
        operation = find_operation
        if operation.state.in?(CompanionOperation::ACTIVE_STATES) && operation.deadline.past?
          operation.update!(state: "timed_out", outcome: "deadline")
        end
        render json: presented(operation)
      end

      def body
        saved = find_operation.take_body!
        return head :gone unless saved

        response.headers["Cache-Control"] = "no-store"
        send_data saved[0], type: saved[1], disposition: "attachment", filename: "companion-result"
      end

      def input
        return head :unsupported_media_type unless request.media_type == "application/octet-stream"
        return head :content_too_large if request.content_length.to_i > CompanionOperation::MAX_BODY

        data = request.body.read(CompanionOperation::MAX_BODY + 1) || "".b
        return head :content_too_large if data.bytesize > CompanionOperation::MAX_BODY

        operation = find_operation
        operation.attach_input!(data)
        operation.dispatch!
        head :created
      rescue CompanionOperation::Refused
        head :conflict
      end

      private

      def require_resident
        head :forbidden unless current_api_agent
      end

      def find_device
        @device = CompanionDevice.where(account_id: current_api_agent.account_id).find(params[:companion_device_id])
      end

      def find_operation
        CompanionOperation.where(companion_device: @device, agent: current_api_agent).find(params[:id])
      end

      def presented(operation)
        { id: operation.obfuscated_id, state: operation.state, outcome: operation.outcome,
          deadline: operation.deadline, body_available: operation.state == "completed" && operation.body.present? }
      end

    end
  end
end
