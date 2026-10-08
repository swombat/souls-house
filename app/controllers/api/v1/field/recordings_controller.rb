module Api
  module V1
    module Field
      # Recordings in the Field. A resident reads its home account's; a person
      # reaches recordings in any account they may act in (ApiHumanReach).
      #
      # Residents read them (spec §7): names are the ones humans set, unnamed
      # speakers are "Speaker N". Nothing inferred, nothing biometric, and no
      # audio or word timings.
      #
      # A person's key gets what their browser gets (FieldRecordingsController):
      # the audio, the timestamped words, speaker ids for naming, and the
      # writes. Recognition and suggestion data stay out of this read; voice
      # prints have their own endpoints under /api/v1/field/voices.
      class RecordingsController < BaseController

        include AttachmentDownloads
        include ApiHumanReach
        include ApiHomeAccountOnly

        HUMAN_ACTIONS = %i[audio create update destroy retry dismiss_you_hint].freeze

        before_action :require_human_actor!, only: HUMAN_ACTIONS
        # A person's reads carry what the browser page shows (audio, timed
        # words, speaker ids), so they need the Field enabled, like the page.
        # A resident's plain read is unchanged.
        require_api_feature_enabled :agents, unless: -> { current_api_agent && !action_name.to_sym.in?(HUMAN_ACTIONS) }
        before_action :set_recording, only: %i[show audio update destroy retry]

        def index
          account = current_api_agent ? current_api_account : human_request_account!
          recordings = account.field_recordings.kept.includes(:uploaded_by).newest_first
          render json: { recordings: recordings.map { |recording| summary_json(recording) } }
        end

        def show
          render json: { recording: current_api_agent ? resident_json(@recording) : person_json(@recording) }
        end

        # The audio, as a short-lived storage URL (like file downloads).
        def audio
          raise ActiveRecord::RecordNotFound unless @recording.audio.attached?

          redirect_to download_url_for(@recording.audio_attachment), allow_other_host: true
        end

        # Step 2: claim the direct upload made through
        # POST /api/v1/field/recordings/uploads.
        def create
          attributes = params.permit(:upload_id, :title, :note, :expected_speakers)
          recording = FieldRecording::Upload.claim!(
            account: human_request_account!,
            user: current_api_user,
            signed_id: attributes[:upload_id],
            attributes: attributes.slice(:title, :note, :expected_speakers).to_h.symbolize_keys
          )

          unless recording
            return render json: { error: "That upload can't be used. Please upload the file again." },
              status: :unprocessable_entity
          end

          FieldRecordings::ProbeJob.perform_later(recording.id)
          render json: { recording: person_json(recording) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end

        def update
          attributes = params.permit(:title, :note)
          return render json: { error: "Provide title or note" }, status: :unprocessable_entity if attributes.empty?

          if @recording.update(attributes)
            render json: { recording: person_json(@recording) }
          else
            render json: { error: @recording.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        def destroy
          @recording.discard_and_settle!
          head :no_content
        end

        # Tries a failed or rejected recording again as a new recording, the
        # same as "Try again" on the page. Returns the new recording.
        def retry
          recording = @recording.retry!(by: current_api_user)
          FieldRecordings::ProbeJob.perform_later(recording.id)
          render json: { recording: person_json(recording) }, status: :created
        rescue FieldRecording::NotRetryable
          render json: { error: "This recording can't be tried again." }, status: :unprocessable_entity
        end

        # "Is one of these you?" is shown once, until dismissed or answered.
        def dismiss_you_hint
          human_request_account!
          current_api_user.update_column(:field_you_hint_dismissed_at, Time.current)
          head :no_content
        end

        private

        # A resident reads in its home account, as before. A person finds the
        # recording in any account they may reach, and acts in its account.
        def set_recording
          @recording = if current_api_agent
            current_api_account.field_recordings.kept.find(params[:id])
          else
            find_human_record!(FieldRecording.kept, params[:id])
          end
        end

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

        def resident_json(recording)
          summary_json(recording).merge(
            transcript_text: (recording.transcript_text if recording.ready?),
            speakers: recording.speakers.includes(:field_voice).map do |speaker|
              { label: speaker.default_name, name: speaker.display_name, talk_ms: speaker.talk_ms }
            end
          )
        end

        # Words are the stored compact form the page uses: s/e (start and end
        # ms), t (text), k (w word, s spacing, a audio event) and spk (the
        # speaker's label).
        def person_json(recording)
          summary_json(recording).merge(
            failure_reason: recording.failure_reason,
            expected_speakers: recording.expected_speakers,
            filename: recording.filename,
            byte_size: recording.byte_size,
            dispatched: recording.dispatch_count.positive?,
            retryable: recording.kept? && FieldRecording::RETRYABLE_STATUSES.include?(recording.status) &&
              recording.audio.attached?,
            audio_path: (audio_api_v1_field_recording_path(recording) if recording.audio.attached?),
            transcript_text: (recording.transcript_text if recording.ready?),
            words: recording.ready? ? recording.transcript_words : [],
            speakers: recording.speakers.includes(:field_voice).map { |speaker| FieldItems.plain_speaker_json(speaker) },
            show_you_hint: show_you_hint?(recording)
          )
        end

        def show_you_hint?(recording)
          recording.ready? && recording.uploaded_by == current_api_user &&
            current_api_user.field_you_hint_dismissed_at.nil? &&
            !recording.account.field_voices.kept.exists?(user: current_api_user)
        end

      end
    end
  end
end
