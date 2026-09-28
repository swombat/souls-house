module Api
  module App
    module V1
      # Direct upload with the app token (#94 B, step 4c). The phone declares a
      # file, gets a short-lived storage URL, PUTs the bytes straight there, and
      # then sends a message naming the returned signed id. The blob remembers
      # who asked and for which conversation; messages#create checks both, so
      # the upload grants nothing outside the conversation it was made for.
      class UploadsController < BaseController

        CHECKSUM_FORMAT = %r{\A[A-Za-z0-9+/]{22}==\z} # base64 MD5, as ActiveStorage expects

        before_action :set_conversation

        def create
          unless @chat.respondable?
            return render_error(:unprocessable_entity, "conversation_not_respondable", "This conversation is archived and cannot receive new messages")
          end

          filename = params[:filename]
          content_type = params[:content_type]
          checksum = params[:checksum]
          byte_size = Integer(params[:byte_size].to_s, 10, exception: false)

          unless filename.is_a?(String) && filename.present? && filename.length <= 255
            return render_error(:unprocessable_entity, "invalid_parameter", "filename is required", { parameter: "filename" })
          end
          unless content_type.is_a?(String) && content_type.match?(%r{\A[\w.+-]+/[\w.+-]+\z})
            return render_error(:unprocessable_entity, "invalid_parameter", "content_type must be a MIME type", { parameter: "content_type" })
          end
          unless checksum.is_a?(String) && checksum.match?(CHECKSUM_FORMAT)
            return render_error(:unprocessable_entity, "invalid_parameter", "checksum must be the file's base64 MD5", { parameter: "checksum" })
          end
          unless byte_size && byte_size.between?(1, Message::Attachable::MAX_FILE_SIZE)
            return render_error(:unprocessable_entity, "invalid_parameter",
                                "byte_size must be 1..#{Message::Attachable::MAX_FILE_SIZE}", { parameter: "byte_size" })
          end

          blob = ActiveStorage::Blob.create_before_direct_upload!(
            filename: filename, byte_size: byte_size, checksum: checksum, content_type: content_type,
            metadata: { "app_upload" => { "user_id" => current_user.id, "chat_id" => @chat.id, "app_session_id" => current_app_session.id } }
          )

          url = with_storage_urls { blob.service_url_for_direct_upload }
          render json: {
            upload: {
              id: blob.signed_id,
              direct_upload: { method: "PUT", url: url, headers: blob.service_headers_for_direct_upload }
            }
          }, status: :created
        end

        private

        def set_conversation
          @chat = find_conversation!(params[:conversation_id])
        end

      end
    end
  end
end
