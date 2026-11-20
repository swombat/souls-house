module Api
  module V1
    module Companion
      # A pocket device posts one voice clip or photo into its conversation.
      # The current device credential is the only authority, as for companion
      # results; never an API key, session or cookie. See CompanionDevice::Pocket.
      #
      # A retry with the same request_id returns the message the first one
      # made: one message, one wake. A clip is transcribed before anything is
      # written, so a refused or silent clip leaves no message and wakes nobody.
      class PocketSubmissionsController < ActionController::API

        REQUEST_ID = /\A[A-Za-z0-9_.:-]{1,64}\z/
        NO_SPEECH = "(The stone heard no speech.)".freeze

        before_action { response.headers["Cache-Control"] = "no-store" }

        def create
          device = CompanionDevice.authenticate(request.authorization.to_s.delete_prefix("Bearer "))
          return render json: { code: "unauthorized" }, status: :unauthorized unless device
          return refuse("not_pocket", :forbidden) unless device.pocket?

          request_id = params[:request_id]
          return refuse("invalid_request_id", :unprocessable_entity) unless request_id.is_a?(String) && REQUEST_ID.match?(request_id)

          client_message_id = "pocket:#{device.to_param}:#{request_id}"
          if (existing = device.chat.messages.find_by(client_message_id: client_message_id, companion_device_id: device.id))
            return render json: { submission_id: existing.to_param, duplicate: true }, status: :ok
          end

          media_kind = params[:kind].to_s
          spec = device.pocket_precheck!(media_kind)
          file = params[:file]
          return refuse("file_required", :unprocessable_entity) unless file.is_a?(ActionDispatch::Http::UploadedFile)
          return refuse("too_large", :content_too_large) if file.size > spec[:max]
          return refuse("unsupported_type", :unsupported_media_type) unless spec[:types].include?(file.content_type.to_s.split(";").first)

          result = media_kind == "voice" ? post_voice(device, file, client_message_id) : post_photo(device, file, client_message_id)
          return if performed?

          if result.created?
            render json: { submission_id: result.message.to_param }, status: :created
          elsif result.duplicate?
            render json: { submission_id: result.message.to_param, duplicate: true }, status: :ok
          else
            refuse("not_accepted", :service_unavailable)
          end
        rescue CompanionDevice::Pocket::Refused => error
          refuse(error.code, error.status)
        rescue ElevenLabsStt::Error, TranscriptionCharge::Refused
          refuse("transcription_failed", :service_unavailable)
        end

        private

        def refuse(code, status)
          render json: { code: code }, status: status
        end

        def post_voice(device, file, client_message_id)
          owner = device.companion_enrollment_grant.created_by_user
          file.tempfile.rewind
          blob = ActiveStorage::Blob.create_and_upload!(io: file.tempfile, filename: "stone.#{file.content_type.include?("webm") ? "webm" : "wav"}",
            content_type: file.content_type, metadata: { VoiceNote::METADATA_KEY => VoiceNote.metadata_for(user: owner, account: device.account, chat: device.chat) })
          file.tempfile.rewind
          TranscriptionCharge.admit!(account: device.account, source: "voice_note", key: blob.id, path: file.tempfile.path)
          file.tempfile.rewind
          text = ElevenLabsStt.transcribe(file, keyterms: TranscriptionGlossary.keyterms_for(device.account))
          device.post_pocket_submission!(media_kind: "voice", content: text.presence || NO_SPEECH,
            client_message_id: client_message_id, audio_signed_id: blob.signed_id).tap do |result|
            VoiceNote.discard!(blob) unless result.created?
          end
        end

        def post_photo(device, file, client_message_id)
          device.post_pocket_submission!(media_kind: "photo", content: "", client_message_id: client_message_id, files: [ file ])
        end

      end
    end
  end
end
