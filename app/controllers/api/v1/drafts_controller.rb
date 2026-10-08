module Api
  module V1
    class DraftsController < BaseController

      before_action :require_human_key
      include ConversationDraftActions

      private

      def require_human_key
        head :forbidden if current_api_agent
      end

      def conversation_draft
        @conversation_draft ||= begin
          chat = human_chats.find(params[:conversation_id])
          current_api_user.confirmed_accounts.find(chat.account_id)
          ConversationDraft.for(chat: chat, user: current_api_user)
        end
      end

    end
  end
end
