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
        latest = current_api_agent.agent_runtime_interactions.where.not(finished_at: nil).order(id: :desc).first
        {
          hook_expectations: current_api_agent.hook_expectations || {},
          events: HookPresence::EVENTS,
          states: HookPresence::STATES,
          latest_run: latest && {
            id: latest.id,
            finished_at: latest.finished_at&.iso8601,
            hook_warning: latest.hook_warning,
            hooks: latest.response_body.is_a?(Hash) ? latest.response_body.dig("telemetry", "hooks") : nil
          }
        }
      end

    end
  end
end
