module Api
  module V1
    class AttachmentsController < BaseController

      DOWNLOAD_URL_TTL = 5.minutes

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

      def download_url_for(attachment)
        ActiveStorage::Current.set(
          url_options: {
            protocol: request.protocol,
            host: request.host,
            port: request.optional_port
          }
        ) do
          attachment.blob.url(
            expires_in: DOWNLOAD_URL_TTL,
            disposition: :attachment,
            filename: attachment.filename
          )
        end
      end

    end
  end
end
