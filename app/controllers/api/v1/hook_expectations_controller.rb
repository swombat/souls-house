module Api
  module V1
    # A resident's own Chaos hook expectations (jaMBVj; see HookPresence).
    # GET shows what its runs are held to and what the latest run found.
    # PATCH sets one event: {"event": "session_start", "state": "off"} when a
    # removal is on purpose, or "expected" to hold runs to it again.
    class HookExpectationsController < BaseController

      before_action :require_resident!

      def show
        render json: payload
      end

      def update
        current_api_agent.set_hook_expectation!(params.require(:event), params.require(:state), source: "resident")
        render json: payload
      rescue ArgumentError => error
        render json: { error: error.message }, status: :unprocessable_entity
      end

      private

      def require_resident!
        response.headers["Cache-Control"] = "no-store"
        return if current_api_agent

        render json: { error: "Hook expectations are only available to resident API keys" }, status: :forbidden
      end

      def payload
        HookPresence.expectations_payload(current_api_agent)
      end

    end
  end
end
