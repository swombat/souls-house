module Api
  module V1
    class MessageRestoresController < BaseController

      include ApiHumanConversation

      before_action :require_human_actor!
      before_action :require_chats_feature!
      before_action :require_system_administrator!

      def create
        chat = human_chat!
        message = chat.messages.find(params[:message_id])
        message.with_lock do
          if message.discarded?
            message.undiscard!
            audit_human_action("restore_message", message, account: chat.account,
              conversation_id: chat.to_param, revision: message.revision)
          end
        end

        response.headers["Cache-Control"] = "no-store"
        render json: { message: {
          id: message.to_param, conversation_id: chat.to_param,
          revision: message.revision, discarded: false
        } }
      end

      private

      def require_system_administrator!
        unless current_api_user&.is_site_admin?
          render json: { error: "A system administrator is required" }, status: :forbidden
        end
      end

    end
  end
end
