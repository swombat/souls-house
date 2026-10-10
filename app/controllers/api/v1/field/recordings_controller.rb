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
        include FieldTagsJson

        class BadParam < StandardError; end

        HUMAN_ACTIONS = %i[audio create update destroy retry dismiss_you_hint].freeze

        before_action :require_human_actor!, only: HUMAN_ACTIONS
        # A person's reads carry what the browser page shows (audio, timed
        # words, speaker ids), so they need the Field enabled, like the page.
        # A resident's plain read is unchanged.
        require_api_feature_enabled :agents, unless: -> { current_api_agent && !action_name.to_sym.in?(HUMAN_ACTIONS) }
        before_action :set_recording, only: %i[show audio update destroy retry]

        # tag=life (repeatable) keeps recordings carrying every one of those tags.
        def index
          return unless (tags = tag_params)

          account = current_api_agent ? current_api_account : human_request_account!
          recordings = with_all_tags(account.field_recordings.kept, tags).includes(:uploaded_by).newest_first
          recordings = recordings.where(import_key: params[:import_key].to_s.strip) if params[:import_key].present?
          recordings = recordings.to_a
          @tag_names = FieldTagging.names_for(recordings)
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
        # POST /api/v1/field/recordings/uploads. With transcript_text or
        # transcript_turns the recording arrives with its transcript and lands
        # ready (FieldRecording#store_supplied_transcript!). import_key makes
        # the call safe to repeat: the same key returns the recording it made
        # (as it is: tags sent with a repeat are not applied; use .../tags).
        # tags: [...] tags a new recording as it arrives.
        def create
          account = human_request_account!
          attributes = params.permit(:upload_id, :title, :note, :expected_speakers, :source_path, :recorded_at,
            :import_key, :language_code)
          tags = FieldTag.normalize_list(FieldTag.list_param(params, :tags) || [])
          if tags.size > FieldTag::MAX_PER_ITEM
            return render json: { error: "An item can carry at most #{FieldTag::MAX_PER_ITEM} tags" }, status: :unprocessable_entity
          end
          return if render_existing_import(account, attributes[:import_key])

          turns = supplied_turns
          if attributes[:language_code].present? && !turns
            return render json: { error: "language_code goes with a supplied transcript" }, status: :unprocessable_entity
          end

          recording = FieldRecording::Upload.claim!(
            account:,
            user: current_api_user,
            signed_id: attributes[:upload_id],
            attributes: recording_attributes(attributes, supplied: turns.present?),
            supplied_turns: turns
          )

          unless recording
            # A retry of the same call can lose the race for its own upload:
            # both miss the lookup above, the first claims the blob, and the
            # second finds it attached. The key then names what was made.
            return if render_existing_import(account, attributes[:import_key])

            return render json: { error: "That upload can't be used. Please upload the file again." },
              status: :unprocessable_entity
          end

          FieldRecordings::ProbeJob.perform_later(recording.id)
          recording.change_tags!(by: current_api_user, add: tags) if tags.any?
          render json: { recording: person_json(recording) }, status: :created
        rescue FieldRecording::SuppliedTranscript::Invalid, BadParam, FieldTag::Invalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          # A concurrent call with the same key won the race.
          render_existing_import(account, attributes[:import_key]) ||
            render(json: { error: "That import is already in progress." }, status: :conflict)
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

        # The same import_key again: the recording it made (200, existing:
        # true), whose upload this call leaves unclaimed for the orphan sweep.
        # Deleted since: 409, so rerunning an import never brings it back.
        # Not derived from filenames, so two files that share one stay two.
        def render_existing_import(account, key)
          key = key.to_s.strip
          return false if key.empty?

          existing = account.field_recordings.find_by(import_key: key)
          return false unless existing

          if existing.kept?
            render json: { recording: person_json(existing), existing: true }, status: :ok
          else
            render json: { error: "A recording imported with this key was deleted.", import_key: key }, status: :conflict
          end
          true
        end

        # nil, or turns from transcript_turns (structured) or transcript_text.
        def supplied_turns
          if params.key?(:transcript_turns) && params.key?(:transcript_text)
            raise FieldRecording::SuppliedTranscript::Invalid, "Send transcript_turns or transcript_text, not both."
          end

          if params.key?(:transcript_turns)
            raw = params[:transcript_turns]
            raise FieldRecording::SuppliedTranscript::Invalid, "transcript_turns must be a list" unless raw.is_a?(Array)

            FieldRecording::SuppliedTranscript.from_turns(raw.map do |turn|
              raise FieldRecording::SuppliedTranscript::Invalid, "each turn must be an object" unless turn.respond_to?(:permit)

              turn.permit(:speaker, :start_ms, :text).to_h
            end)
          elsif params.key?(:transcript_text)
            FieldRecording::SuppliedTranscript.parse(params[:transcript_text])
          end
        end

        def recording_attributes(attributes, supplied:)
          permitted = %i[title note source_path import_key]
          permitted << (supplied ? :language_code : :expected_speakers)
          values = attributes.slice(*permitted).to_h.symbolize_keys
          values[:recorded_at] = recorded_at(attributes[:recorded_at]) if attributes[:recorded_at].present?
          values
        end

        # ISO 8601, a date or a time. Anything else is refused rather than
        # silently stored as nothing.
        def recorded_at(value)
          Time.iso8601(value.to_s)
        rescue ArgumentError
          begin
            Date.iso8601(value.to_s).in_time_zone
          rescue Date::Error
            raise BadParam, "recorded_at must be an ISO 8601 date or time"
          end
        end

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
            summary_short: recording.summary_short,
            summary_long: recording.summary_long,
            status: recording.status,
            duration_ms: recording.duration_ms,
            language_code: recording.language_code,
            uploaded_by: { kind: recording.uploader_kind, name: recording.uploader_name },
            created_at: recording.created_at.iso8601,
            ready_at: recording.ready_at&.iso8601,
            transcript_source: recording.transcript_source,
            recorded_at: recording.recorded_at&.iso8601,
            source_path: recording.source_path,
            import_key: recording.import_key,
            tags: @tag_names ? (@tag_names[[ "FieldRecording", recording.id ]] || []) : recording.tag_names
          }
        end

        def resident_json(recording)
          summary_json(recording).merge(
            transcript_text: (recording.transcript_text if recording.ready?),
            speakers: recording.speakers.includes(:field_voice).map do |speaker|
              { label: speaker.default_name, name: speaker.display_name, talk_ms: speaker.known_talk_ms }
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
            turns: (recording.transcript_turns if recording.ready? && recording.supplied?),
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
