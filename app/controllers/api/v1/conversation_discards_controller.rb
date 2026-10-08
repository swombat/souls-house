module Api
  module V1
    # chats/discards for a person's key: delete (discard) and restore, for
    # someone who can manage the account. Repeating either is a no-op.
    class ConversationDiscardsController < BaseController

      include ApiConversationJson
      include ApiHumanActions

      before_action :require_human_key
      before_action :set_chat
      before_action :require_manager

      # POST /api/v1/conversations/:conversation_id/discard
      def create
        unless @chat.discarded?
          @chat.discard!
          audit("discard_chat", @chat)
        end
        render json: { conversation: conversation_json(@chat) }
      end

      # DELETE /api/v1/conversations/:conversation_id/discard
      def destroy
        if @chat.discarded?
          @chat.undiscard!
          audit("restore_chat", @chat)
        end
        render json: { conversation: conversation_json(@chat) }
      end

      private

      # Deleted conversations too, so they can be restored.
      def set_chat
        @chat = member_account.chats.with_discarded.find(params[:conversation_id])
      end

      def require_manager
        return if member_account.manageable_by?(current_api_user)

        render json: { error: "Only someone who can manage this account can delete or restore conversations" }, status: :forbidden
      end

    end
  end
end
