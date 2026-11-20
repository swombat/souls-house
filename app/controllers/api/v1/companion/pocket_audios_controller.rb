module Api
  module V1
    module Companion
      # A pocket device fetches the voice of the last reply it was sent. The
      # current device credential is the only authority, as for submissions:
      # a revoked or paused device is refused, and a device only ever reaches
      # its own last reply, within CompanionDevice::Pocket::AUDIO_WINDOW. The
      # answer is a redirect to a storage link that lasts LINK_TTL, so no
      # lasting link goes down the cable or into the firmware (Mira, JkRXoj).
      class PocketAudiosController < ActionController::API

        LINK_TTL = 5.minutes

        before_action { response.headers["Cache-Control"] = "no-store" }

        def show
          device = CompanionDevice.authenticate(request.authorization.to_s.delete_prefix("Bearer "))
          return render json: { code: "unauthorized" }, status: :unauthorized unless device
          return render json: { code: "not_pocket" }, status: :forbidden unless device.pocket?

          reply = device.pocket_reply
          return render json: { code: "not_found" }, status: :not_found unless reply && reply.to_param == params[:message_id].to_s
          return render json: { code: "not_ready" }, status: :accepted unless reply.voice_audio_current?

          url = ActiveStorage::Current.set(url_options: { protocol: request.protocol, host: request.host, port: request.optional_port }) do
            reply.voice_audio.blob.url(expires_in: LINK_TTL, disposition: :inline, filename: reply.voice_audio.filename)
          end
          redirect_to url, allow_other_host: true
        end

      end
    end
  end
end
