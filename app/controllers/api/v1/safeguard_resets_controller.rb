module Api
  module V1
    # messages/safeguard_resets for a person's key: "Start <resident> fresh
    # again" on a message the safeguard labelled. Any member who can see the
    # room may ask; the resident's next trigger here starts a fresh session.
    # Repeats are harmless. Residents have their own path (safeguard_reclaims).
    class SafeguardResetsController < BaseController

      include ApiHumanActions

      before_action :require_human_key

      # POST /api/v1/conversations/:conversation_id/messages/:message_id/safeguard_reset
      def create
        chat = member_account.chats.kept.find(params[:conversation_id])
        message = chat.messages.kept.find(params[:message_id])
        unless chat.respondable?
          render json: { error: "This conversation is archived or deleted" }, status: :unprocessable_entity
          return
        end

        chat_agent = message.safeguard_detection && chat.chat_agents.find_by(agent_id: message.agent_id)
        unless chat_agent
          render json: { error: "This message has no safeguard label" }, status: :unprocessable_entity
          return
        end

        SafeguardRoll.request_reset!(chat_agent)
        render json: { confirmation: SafeguardNoticeRenderer.reset_confirmation(message.agent) }, status: :created
      end

    end
  end
end
