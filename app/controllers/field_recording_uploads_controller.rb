# Step 1 of bringing a recording into the Field (spec §4): declare the file
# and get a direct-upload URL. The response has the same shape as Active
# Storage's own direct-uploads endpoint, so its JavaScript DirectUpload can use
# this URL unchanged.
class FieldRecordingUploadsController < ApplicationController

  include ActiveStorage::SetCurrent # storage URLs need the request host

  require_feature_enabled :agents

  def create
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

    blob = FieldRecording::Upload.create_blob!(account: current_account, user: Current.user, **declaration)
    render json: blob.as_json(root: false, methods: :signed_id, only: %i[id key filename content_type byte_size checksum])
      .merge(direct_upload: { url: blob.service_url_for_direct_upload, headers: blob.service_headers_for_direct_upload })
  end

end
