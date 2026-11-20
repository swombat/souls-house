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
          # The bytes decide, not the multipart label (Mira, JnwomB).
          sniffed = sniff(file)
          return refuse("unsupported_type", :unsupported_media_type) unless sniffed && spec[:types].include?(sniffed)
          file.content_type = sniffed

          result = media_kind == "voice" ? post_voice(device, file, sniffed, client_message_id) : post_photo(device, file, client_message_id)
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

        # Leading bytes of each accepted format.
        def sniff(file)
          file.tempfile.rewind
          head = file.tempfile.read(12).to_s.b
          file.tempfile.rewind
          if head.start_with?("\xFF\xD8\xFF".b) then "image/jpeg"
          elsif head.start_with?("RIFF".b) && head[8, 4] == "WAVE".b then "audio/wav"
          elsif head.start_with?("\x1A\x45\xDF\xA3".b) then "audio/webm"
          end
        end

        def clip_ms(file)
          path = file.tempfile.path
          FieldRecording::Probe.duration_ms(path) || FieldRecording::Probe.packet_duration_ms(path)
        end

        # The stored clip is removed on every path that doesn't end in an
        # accepted message: refused, raised, or a duplicate retry. Once a
        # message holds it, it's attached and discard! leaves it alone.
        def post_voice(device, file, content_type, client_message_id)
          duration = clip_ms(file)
          raise CompanionDevice::Pocket::Refused.new("unreadable_media", :unsupported_media_type) unless duration
          raise CompanionDevice::Pocket::Refused.new("too_long", :content_too_large) if duration > CompanionDevice::Pocket::MAX_CLIP_SECONDS * 1000

          owner = device.companion_enrollment_grant.created_by_user
          file.tempfile.rewind
          blob = ActiveStorage::Blob.create_and_upload!(io: file.tempfile, filename: "stone.#{content_type == "audio/webm" ? "webm" : "wav"}",
            content_type: content_type, metadata: { VoiceNote::METADATA_KEY => VoiceNote.metadata_for(user: owner, account: device.account, chat: device.chat) })
          file.tempfile.rewind
          TranscriptionCharge.admit!(account: device.account, source: "voice_note", key: blob.id, path: file.tempfile.path)
          file.tempfile.rewind
          text = ElevenLabsStt.transcribe(file, keyterms: TranscriptionGlossary.keyterms_for(device.account))
          device.post_pocket_submission!(media_kind: "voice", content: text.presence || NO_SPEECH,
            client_message_id: client_message_id, audio_signed_id: blob.signed_id)
        ensure
          VoiceNote.discard!(blob) if blob
        end

        def post_photo(device, file, client_message_id)
          device.post_pocket_submission!(media_kind: "photo", content: "", client_message_id: client_message_id, files: [ file ])
        end

      end
    end
  end
end
