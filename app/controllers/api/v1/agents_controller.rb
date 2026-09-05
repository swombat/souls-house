module Api
  module V1
    class AgentsController < BaseController

      skip_before_action :authenticate_api_key!, only: [ :announce ]
      before_action :find_agent_by_uuid, only: [ :announce, :health ]
      before_action :authenticate_with_trigger_token, only: [ :announce ]

      def index
        agents = current_api_account.agents.active.by_name
        render json: { agents: agents.map { |a| agent_json(a) } }
      end

      def show
        agent = current_api_account.agents.find(params[:id])
        render json: { agent: agent_json(agent) }
      end

      def announce
        unless @agent.hosted?
          return render json: { error: "Agent is deprecated", code: "agent_deprecated" }, status: :conflict
        end

        @agent.update!(
          endpoint_url: params.require(:endpoint_url),
          last_announced_at: Time.current,
          runtime: "external",
          health_state: "healthy",
          consecutive_health_failures: 0
        )

        render json: { status: "ok", endpoint_url: @agent.endpoint_url }
      end

      def health
        render json: {
          runtime: @agent.runtime,
          health_state: @agent.health_state,
          last_check: @agent.last_health_check_at
        }
      end

      private

      def find_agent_by_uuid
        @agent = Agent.find_by!(uuid: params[:uuid])
      end

      def authenticate_with_trigger_token
        token = request.headers["Authorization"]&.delete_prefix("Bearer ")
        expected = @agent.trigger_bearer_token

        return render json: { error: "Invalid or missing trigger token" }, status: :unauthorized if token.blank? || expected.blank?
        render json: { error: "Invalid or missing trigger token" }, status: :unauthorized unless secure_token_match?(token, expected)
      end

      def secure_token_match?(token, expected)
        ActiveSupport::SecurityUtils.secure_compare(token, expected)
      rescue ArgumentError
        false
      end

      def agent_json(agent)
        {
          id: agent.to_param,
          name: agent.name,
          model: agent.model_label,
          colour: agent.colour,
          icon: agent.icon,
          active: agent.active?,
          runtime: agent.runtime,
          deprecated: agent.deprecated?,
          unavailability_reason: agent.unavailability_reason
        }
      end

    end
  end
end
