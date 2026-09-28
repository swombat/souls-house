module Api
  module App
    module V1
      # An attachment of a visible message, as a redirect to a short-lived
      # storage URL (#94 B, step 4c). Same authority as reading the message:
      # current membership, a kept message, and not a reply still streaming
      # (whose attachments the presenter withholds). The redirect leaves this
      # origin, so clients must not forward the bearer to it (ADR 0005).
      class AttachmentsController < BaseController

        DOWNLOAD_URL_TTL = 5.minutes

        def show
          chat = find_conversation!(params[:conversation_id])
          message = chat.messages.kept.find(params[:message_id])
          raise ActiveRecord::RecordNotFound if message.streaming?

          attachment = message.attachments_attachments.find(params[:id])
          response.headers["Cache-Control"] = "no-store"
          redirect_to download_url_for(attachment), allow_other_host: true
        end

        private

        def download_url_for(attachment)
          with_storage_urls do
            attachment.blob.url(expires_in: DOWNLOAD_URL_TTL, disposition: :attachment, filename: attachment.filename)
          end
        end

      end
    end
  end
end
