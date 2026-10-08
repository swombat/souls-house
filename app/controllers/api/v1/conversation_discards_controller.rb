module Api
  module V1
    # chats/discards for a person's credential: delete (discard) and restore,
    # for someone who can manage the room's account. Repeating either is a
    # no-op.
    class ConversationDiscardsController < BaseController

      include ApiConversationJson
      include ApiHumanConversation

      before_action :require_human_actor!
      before_action :require_chats_feature!
      before_action :set_chat
      before_action :require_manager

      # POST /api/v1/conversations/:conversation_id/discard
      def create
        unless @chat.discarded?
          @chat.discard!
          audit_human_action("discard_chat", @chat, account: @chat.account)
        end
        render json: { conversation: conversation_json(@chat) }
      end

      # DELETE /api/v1/conversations/:conversation_id/discard
      def destroy
        if @chat.discarded?
          @chat.undiscard!
          audit_human_action("restore_chat", @chat, account: @chat.account)
        end
        render json: { conversation: conversation_json(@chat) }
      end

      private

      # Deleted conversations too, so they can be restored.
      def set_chat
        @chat = human_chat!(human_chats.with_discarded)
      end

      def require_manager
        return if @chat.account.manageable_by?(current_api_user)

        render json: { error: "Only someone who can manage this account can delete or restore conversations" }, status: :forbidden
      end

    end
  end
end
