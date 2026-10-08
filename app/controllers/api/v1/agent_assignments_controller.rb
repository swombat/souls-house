module Api
  module V1
    # chats/agent_assignments for a person's credential: hand a conversation
    # that is still with a bare model to one of its account's residents.
    class AgentAssignmentsController < BaseController

      include ApiConversationJson
      include ApiHumanConversation

      before_action :require_human_actor!
      before_action :require_chats_feature!

      # POST /api/v1/conversations/:conversation_id/agent_assignment
      def create
        chat = human_chat!
        agent_id = params[:agent_id]
        unless agent_id.is_a?(String) && agent_id.present?
          render json: { error: "agent_id must be a nonblank resident ID" }, status: :unprocessable_entity
          return
        end
        return render_already_assigned if chat.manual_responses?

        agent = chat.account.conversation_agents.eligible_for_conversation.find(agent_id)
        chat.assign_agent!(agent)
        audit_human_action("assign_agent_to_chat", chat, account: chat.account, agent_id: agent.id)
        render json: { conversation: conversation_json(chat), agent: { id: agent.to_param, name: agent.name } }
      rescue Chat::AgentAssignable::AlreadyAssigned
        render_already_assigned
      end

      private

      def render_already_assigned
        render json: { error: "This conversation is already assigned to a resident", code: "already_assigned" }, status: :conflict
      end

    end
  end
end
