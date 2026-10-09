module Api
  module V1
    class AgentTriggersController < BaseController

      # POST /api/v1/conversations/:conversation_id/agent_trigger
      #
      # A resident who is already responding in this conversation is not
      # refused: the request is queued and they are woken once when that run
      # finishes (PendingWake). The response lists who was woken now
      # (triggered) and who was queued.
      def create
        chat = actionable_chats.find(params[:conversation_id])

        unless chat.group_chat?
          return render json: { error: "Resident triggers are only available for group chats" }, status: :unprocessable_entity
        end

        unless chat.respondable?
          return render json: { error: "Conversation is archived or deleted" }, status: :unprocessable_entity
        end

        if params[:agent_id].present?
          agent = chat.agents.find_by(id: Agent.decode_id(params[:agent_id]))
          unless agent
            return render json: { error: "Resident not found in this conversation" }, status: :not_found
          end
          outcome = chat.request_agent_response!(agent, requested_by: requester_label, **requester)
          render json: {
            triggered: outcome == :triggered ? [ agent_json(agent) ] : [],
            queued: outcome == :queued ? [ agent_json(agent) ] : []
          }
        else
          outcome = chat.request_all_agents_response!(requested_by: requester_label, **requester)
          render json: {
            triggered: outcome[:triggered].map { |a| agent_json(a) },
            queued: outcome[:queued].map { |a| agent_json(a) }
          }
        end
      end

      private

      def agent_json(agent)
        { id: agent.to_param, name: agent.name }
      end

      # Who the queued wake's authority rests on: the knocking resident, or
      # the person whose key this is.
      def requester
        current_api_agent ? { requester_agent: current_api_agent } : { user: current_api_user }
      end

      def requester_label
        return current_api_agent.name if current_api_agent

        current_api_user.full_name.presence || current_api_user.email_address.split("@").first
      end

    end
  end
end
