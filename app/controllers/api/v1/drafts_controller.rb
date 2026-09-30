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
          account = current_api_user.confirmed_accounts.find(current_api_account.id)
          chat = account.chats.find(params[:conversation_id])
          ConversationDraft.for(chat: chat, user: current_api_user)
        end
      end

    end
  end
end
