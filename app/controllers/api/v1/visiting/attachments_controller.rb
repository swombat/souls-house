module Api
  module V1
    module Visiting
      # Served directly, not redirected: the visitor's home refuses redirects.
      class AttachmentsController < BaseController

        MAX_BYTES = 20.megabytes

        before_action :authenticate_visit!

        def show
          chat = seated_chat!
          # Only what the transcript lists (Message#attachments_for_api): a
          # message's files and its voice recording, never generated voice
          # audio or anything else attached to a message.
          row = ActiveStorage::Attachment.where(record_type: "Message", name: %w[attachments audio_recording],
            record_id: chat.messages.kept.select(:id)).find_by!(id: params[:id])
          attachment = row.record.api_downloadable_attachment(row.id) || raise(ActiveRecord::RecordNotFound)
          blob = attachment.blob
          return render json: { error: "Attachment too large" }, status: :content_too_large if blob.byte_size > MAX_BYTES

          send_data blob.download, filename: blob.filename.to_s, type: blob.content_type, disposition: "attachment"
        end

      end
    end
  end
end
