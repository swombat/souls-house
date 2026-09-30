module Api
  module V1
    class AgentTriggersController < BaseController

      # POST /api/v1/conversations/:conversation_id/agent_trigger
      def create
        chat = current_api_account.chats.find(params[:conversation_id])

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
          chat.trigger_agent_response!(agent)
          render json: { triggered: [ { id: agent.to_param, name: agent.name } ] }
        else
          chat.trigger_all_agents_response!
          render json: { triggered: chat.agents.map { |a| { id: a.to_param, name: a.name } } }
        end
      end

    end
  end
end
