module Api
  module V1
    class ParticipantsController < BaseController

      include ApiHumanConversation
      before_action :require_human_actor!, only: :destroy
      before_action :require_chats_feature!, only: :destroy

      # DELETE /api/v1/conversations/:conversation_id/participant
      def destroy
        unless params[:agent_id].is_a?(String) && params[:agent_id].present?
          return render json: { error: "agent_id must be a public resident ID" }, status: :unprocessable_entity
        end

        # A home-account owner may withdraw their guest even without being a
        # member of the receiving account. The key remains account-scoped.
        home = current_api_account
        scope = human_chats
        if home.owned_by?(current_api_user)
          guest_seats = ChatAgent.where(agent_id: home.agents.select(:id))
          scope = scope.or(Chat.where(id: guest_seats.select(:chat_id)))
        end
        chat = scope.kept.find(params[:conversation_id])
        agent = chat.agents.find(params[:agent_id])
        unless human_chats.exists?(chat.id) ||
          (agent.account_id == home.id && home.owned_by?(current_api_user))
          return render json: { error: "This credential may only withdraw its own guest" }, status: :forbidden
        end
        chat.remove_participant!(agent, by: current_api_user) do
          audit_human_action("remove_agent_from_chat", chat, account: chat.account, agent_id: agent.id)
        end
        head :no_content
      rescue Chat::AlreadyResponding => error
        render json: { error: error.message, code: "already_responding" }, status: :conflict
      rescue Account::NotAuthorized
        head :forbidden
      end

      # POST /api/v1/conversations/:conversation_id/participants
      def create
        chat = actionable_chats.find(params[:conversation_id])

        unless chat.group_chat?
          return render json: { error: "Can only add residents to group chats" }, status: :unprocessable_entity
        end

        unless chat.respondable?
          return render json: { error: "Conversation is archived or deleted" }, status: :unprocessable_entity
        end

        agent = chat.account.conversation_agents.eligible_for_conversation.find_by(id: Agent.decode_id(params[:agent_id]))
        unless agent
          return render json: { error: "Resident not found or inactive" }, status: :not_found
        end

        chat.with_lock do
          if chat.agents.exists?(agent.id)
            return render json: { error: "#{agent.name} is already in this conversation" }, status: :unprocessable_entity
          end

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
