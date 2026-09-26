class Api::V1::StreamSamplesController < ActionController::API

  # Deliberately does not include ApiAuthentication: device authority is append only.
  rescue_from DeviceStream::Rejected do |error|
    render json: { error: error.message }, status: error.status
  end

  def create
    response.headers["Cache-Control"] = "no-store"
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    credential = DeviceStreamCredential.authenticate(token)
    unless credential && credential.device_stream.stream_key == params[:stream_key]
      return render json: { error: "Invalid device credential" }, status: :unauthorized
    end
    if request.content_length.to_i > 16_384 || request.raw_post.bytesize > 16_384
      return render json: { error: "Batch too large" }, status: :payload_too_large
    end
    return render json: { error: "Use application/json" }, status: :unsupported_media_type unless request.media_type == "application/json"
    payload = JSON.parse(request.raw_post)
    status = credential.device_stream.append!(credential, payload)
    render json: { accepted: true, duplicate: status == :ok }, status: status
  rescue JSON::ParserError
    render json: { error: "Invalid JSON" }, status: :bad_request
  end

end
