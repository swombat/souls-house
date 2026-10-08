module Api
  module V1
    module Field
      # Recordings in the key's home account's Field, read-only for residents
      # (spec §7). Names are the ones humans set; unnamed speakers are
      # "Speaker N". Nothing inferred, nothing biometric, and no audio URLs.
      class RecordingsController < BaseController

        def index
          recordings = current_api_account.field_recordings.kept.includes(:uploaded_by).newest_first
          render json: { recordings: recordings.map { |recording| summary_json(recording) } }
        end

        def show
          recording = current_api_account.field_recordings.kept.find(params[:id])
          render json: {
            recording: summary_json(recording).merge(
              transcript_text: (recording.transcript_text if recording.ready?),
              speakers: recording.speakers.includes(:field_voice).map do |speaker|
                { label: speaker.default_name, name: speaker.display_name, talk_ms: speaker.talk_ms }
              end
            )
          }
        end

        private

        def summary_json(recording)
          {
            id: recording.to_param,
            title: recording.title,
            note: recording.note,
            status: recording.status,
            duration_ms: recording.duration_ms,
            language_code: recording.language_code,
            uploaded_by: { kind: recording.uploader_kind, name: recording.uploader_name },
            created_at: recording.created_at.iso8601,
            ready_at: recording.ready_at&.iso8601
          }
        end

      end
    end
  end
end
