module Api
  module V1
    # chats/archives for a person's key: any member may archive or unarchive.
    class ConversationArchivesController < BaseController

      include ApiConversationJson
      include ApiHumanActions

      before_action :require_human_key
      before_action :set_chat

      # POST /api/v1/conversations/:conversation_id/archive
      def create
        @chat.archive!
        audit("archive_chat", @chat)
        render json: { conversation: conversation_json(@chat) }
      end

      # DELETE /api/v1/conversations/:conversation_id/archive
      def destroy
        @chat.unarchive!
        audit("unarchive_chat", @chat)
        render json: { conversation: conversation_json(@chat) }
      end

      private

      def set_chat
        @chat = member_account.chats.kept.find(params[:conversation_id])
      end

    end
  end
end
