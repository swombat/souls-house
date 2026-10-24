module Api
  module V1
    # The device can consume only its currently dispatched operation's input.
    class CompanionInputsController < ActionController::API

      def show
        device = CompanionDevice.authenticate(request.authorization.to_s.delete_prefix("Bearer "))
        return head :unauthorized unless device

        operation = CompanionOperation.where(companion_device: device).find(params[:id])
        data = operation.take_input!(epoch: request.headers["X-Companion-Epoch"],
          revision: request.headers["X-Companion-Revision"].to_i)
        return head :gone unless data

        response.headers["Cache-Control"] = "no-store"
        send_data data, type: "application/octet-stream", disposition: "attachment", filename: "companion-input"
      rescue ActiveRecord::RecordNotFound, Hashids::InputError
        head :not_found
      end

    end
  end
end
