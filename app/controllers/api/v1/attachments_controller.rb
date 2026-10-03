module Api
  module V1
    class AttachmentsController < BaseController

      include AttachmentDownloads

      def show
        chat = conversations_scope.find(params[:conversation_id])
        message = chat.messages.kept.find(params[:message_id])
        attachment = message.attachments_attachments.find(params[:id])

        redirect_to download_url_for(attachment), allow_other_host: true
      end

      private

      def conversations_scope
        return current_api_agent.chats if current_api_agent

        current_api_account.chats
      end

    end
  end
end
