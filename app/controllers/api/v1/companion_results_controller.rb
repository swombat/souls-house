module Api
  module V1
    # Device credentials only. No API key/session/cookie authentication fallback.
    class CompanionResultsController < ActionController::API

      def create
        device = CompanionDevice.authenticate(request.authorization.to_s.delete_prefix("Bearer "))
        return head :unauthorized unless device
        return head :unsupported_media_type unless request.media_type == "application/octet-stream"
        return head :payload_too_large if request.content_length.to_i > CompanionOperation::MAX_BODY

        operation = CompanionOperation.where(companion_device: device).find(params[:id])
        format = request.headers["X-Companion-Format"]
        return head :unprocessable_entity unless format == "json" || (format == "binary" && operation.kind == "read")
        data = request.body.read(CompanionOperation::MAX_BODY + 1) || "".b
        return head :payload_too_large if data.bytesize > CompanionOperation::MAX_BODY
        return head :content_too_large if format == "json" && operation.kind != "execute" && data.bytesize > CompanionOperation::MAX_INLINE

        accepted = operation.complete!(epoch: request.headers["X-Companion-Epoch"],
          revision: request.headers["X-Companion-Revision"].to_i, data: data,
          error: request.headers["X-Companion-Error"],
          content_type: format == "json" ? "application/json" : "application/octet-stream")
        head accepted ? :created : :conflict
      rescue ActiveRecord::RecordNotFound, Hashids::InputError
        head :not_found
      rescue CompanionOperation::Refused
        head :unprocessable_entity
      end

    end
  end
end
