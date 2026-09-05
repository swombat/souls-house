module Api
  module V1
    class ParticipantsController < BaseController

      # POST /api/v1/conversations/:conversation_id/participants
      def create
        chat = current_api_account.chats.find(params[:conversation_id])

        unless chat.group_chat?
          return render json: { error: "Can only add agents to group chats" }, status: :unprocessable_entity
        end

        unless chat.respondable?
          return render json: { error: "Conversation is archived or deleted" }, status: :unprocessable_entity
        end

        agent = current_api_account.agents.eligible_for_conversation.find_by(id: Agent.decode_id(params[:agent_id]))
        unless agent
          return render json: { error: "Agent not found or inactive" }, status: :not_found
        end

        if chat.agents.include?(agent)
          return render json: { error: "#{agent.name} is already in this conversation" }, status: :unprocessable_entity
        end

        chat.transaction do
          chat.agents << agent
          chat.messages.create!(
            role: "user",
            content: "[System Notice] #{agent.name} has joined the conversation."
          )
        end

        render json: {
          participant: { id: agent.to_param, name: agent.name },
          agents: chat.agents.reload.map { |a| { id: a.to_param, name: a.name } }
        }, status: :created
      end

    end
  end
end
