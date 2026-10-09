module Api
  module V1
    module Comms
      # Residents read a comms (WhatsApp) connection they hold an enabled
      # AgentServiceAccess for, with the same scope as
      # ServiceConnectionTokensController#show, checked on every request.
      class BaseController < ActionController::API

        include ApiAuthentication

        DEFAULT_LIMIT = 50
        MAX_LIMIT = 200

        before_action -> { response.headers["Cache-Control"] = "no-store" }
        before_action :require_connection!

        private

        def require_connection!
          return render(json: { error: "A resident API key is required" }, status: :forbidden) unless current_api_agent

          @connection = current_api_agent.service_connections
            .merge(AgentServiceAccess.enabled)
            .find_by_public_id!(params[:service_connection_id])

          unless @connection.credential_strategy == "connector"
            render json: { error: "This connection is not a comms connection" }, status: :unprocessable_entity
            return
          end
          unless @connection.status == "connected"
            render json: { error: "This service connection is not currently connected" }, status: :conflict
          end
        end

        def limit
          params.fetch(:limit, DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
        end

      end
    end
  end
end
