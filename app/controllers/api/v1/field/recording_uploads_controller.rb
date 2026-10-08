module Api
  module V1
    module Field
      # Step 1 of bringing a recording into the Field, as on the web
      # (FieldRecordingUploadsController): declare the file, get a direct-upload
      # URL, PUT the bytes there, then POST /api/v1/field/recordings with the
      # returned signed_id as upload_id. The blob is pinned to this person and
      # account, so only they can claim it.
      class RecordingUploadsController < BaseController

        include ActiveStorage::SetCurrent # storage URLs need the request host
        include ApiHumanReach

        before_action :require_human_actor!
        require_api_feature_enabled :agents

        def create
          account = human_request_account!
          declared = params.require(:blob).permit(:filename, :content_type, :byte_size, :checksum)
          declaration = {
            filename: declared[:filename],
            content_type: declared[:content_type],
            byte_size: Integer(declared[:byte_size].to_s, 10, exception: false),
            checksum: declared[:checksum]
          }

          unless FieldRecording::Upload.valid_declaration?(**declaration)
            return render json: { error: "Choose an audio or video file up to #{FieldRecording::MAX_BYTES_LABEL}." },
              status: :unprocessable_entity
          end

          blob = FieldRecording::Upload.create_blob!(account: account, user: current_api_user, **declaration)
          render json: blob.as_json(root: false, methods: :signed_id, only: %i[id key filename content_type byte_size checksum])
            .merge(direct_upload: { url: blob.service_url_for_direct_upload, headers: blob.service_headers_for_direct_upload }),
            status: :created
        rescue ActionController::ParameterMissing
          render json: { error: "Provide blob: filename, content_type, byte_size and checksum" }, status: :unprocessable_entity
        end

      end
    end
  end
end
