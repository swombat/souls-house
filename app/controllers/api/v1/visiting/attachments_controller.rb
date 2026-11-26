module Api
  module V1
    module Visiting
      # Served directly, not redirected: the visitor's home refuses redirects.
      class AttachmentsController < BaseController

        MAX_BYTES = 20.megabytes

        before_action :authenticate_visit!

        def show
          chat = seated_chat!
          attachment = ActiveStorage::Attachment.where(record_type: "Message", record_id: chat.messages.kept.select(:id))
            .find_by!(id: params[:id])
          blob = attachment.blob
          return render json: { error: "Attachment too large" }, status: :content_too_large if blob.byte_size > MAX_BYTES

          send_data blob.download, filename: blob.filename.to_s, type: blob.content_type, disposition: "attachment"
        end

      end
    end
  end
end
