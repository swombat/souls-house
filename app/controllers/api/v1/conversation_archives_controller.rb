module Api
  module V1
    # chats/archives for a person's credential: any member may archive or
    # unarchive.
    class ConversationArchivesController < BaseController

      include ApiConversationJson
      include ApiHumanConversation

      before_action :require_human_actor!
      before_action :require_chats_feature!
      before_action :set_chat

      # POST /api/v1/conversations/:conversation_id/archive
      def create
        @chat.archive!
        audit_human_action("archive_chat", @chat, account: @chat.account)
        render json: { conversation: conversation_json(@chat) }
      end

      # DELETE /api/v1/conversations/:conversation_id/archive
      def destroy
        @chat.unarchive!
        audit_human_action("unarchive_chat", @chat, account: @chat.account)
        render json: { conversation: conversation_json(@chat) }
      end

      private

      def set_chat
        @chat = human_chat!
      end

    end
  end
end
