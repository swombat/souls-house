module Api
  module V1
    module Field
      # Voice samples. A person's credential manages every sample in accounts
      # they may act in. A resident key works only in its home account and only
      # with uploaded candidates: it lists, inspects, downloads, uploads,
      # re-attributes, excludes and removes samples no person has confirmed.
      # Confirmation (listening testimony) and any change to a confirmed sample
      # stay a person's; so do recording-backed samples, whose audio and
      # timings residents never read (RecordingsController). Resident writes
      # are audited with the resident as the actor and never carry the key
      # owner as uploader, namer or confirmer.
      class VoiceSamplesController < BaseController

        include ApiHumanReach
        include ApiHomeAccountOnly

        require_api_feature_enabled :agents
        before_action :set_voice
        before_action :set_sample, except: %i[index create]

        rescue_from FieldVoiceprints::Limits::Reached do |error|
          render json: { error: error.message }, status: :conflict
        end
        rescue_from FieldVoiceSamples::Conflict do |error|
          render json: { error: error.message }, status: :conflict
        end
        rescue_from FieldVoiceSamples::Invalid do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end
        rescue_from FieldVoiceSamples::Forbidden do |error|
          render json: { error: error.message }, status: :forbidden
        end

        def index
          rows = samples.order(:id)
          page = [ params[:page].to_i, 1 ].max
          render json: { samples: rows.offset((page - 1) * 50).limit(50).map { |sample| present(sample) },
            page:, total: rows.count, pages: [ (rows.count / 50.0).ceil, 1 ].max,
            limits: { active: 20, pending: 20, minimum_confirmed: 2 } }
        end

        def show
          render json: { sample: present(@sample) }
        end

        def create
          unless params[:idempotency_key].is_a?(String) && params[:idempotency_key].present?
            return render json: { error: "Provide a stable idempotency_key for this upload." }, status: :unprocessable_entity
          end
          metadata = params.permit(:source_identifier, :source_sha256, :source_session,
            :start_ms, :end_ms, :recorded_at, :idempotency_key).to_h
          # A transcript in Field belongs to a recording; both names refer to
          # that account-scoped resource, never an arbitrary foreign row.
          if params[:recording_id].present? || params[:transcript_id].present?
            if params[:recording_id].present? && params[:transcript_id].present? && params[:recording_id] != params[:transcript_id]
              return render json: { error: "recording_id and transcript_id must identify the same recording." }, status: :unprocessable_entity
            end
            recording = @voice.account.field_recordings.kept.find_by!(
              id: FieldRecording.decode_id(params[:recording_id].presence || params[:transcript_id]))
            metadata["field_recording_id"] = recording.id
          end
          result = FieldVoiceSamples::Uploads.create_with_receipt!(voice: @voice, by: testimony_user, file: params[:audio], metadata:)
          sample = result.sample
          audit_resident("field_voice_sample_uploaded", sample, deduplicated: result.deduplicated)
          FieldVoices::LearnUploadJob.queue!(sample)
          render json: { sample: present(sample), deduplicated: result.deduplicated },
            status: result.deduplicated ? :ok : :created
        rescue ActiveRecord::RecordInvalid, ArgumentError => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def update
          if current_api_agent
            if request.request_parameters.key?("voice_id") && params.key?(:included)
              return render json: { error: "Change attribution separately from inclusion." }, status: :unprocessable_entity
            end
            return resident_update
          end
          if request.request_parameters.key?("voice_id")
            return render json: { error: "Change attribution separately from inclusion." }, status: :unprocessable_entity if params.key?(:included)
            target = @voice.account.field_voices.kept.find_by!(id: FieldVoice.decode_id(request.request_parameters["voice_id"]))
            if @sample.field_recording_speaker
              @voice.account.with_lock do
                speaker = @sample.field_recording_speaker
                speaker.field_recording.lock!
                @sample.reload
                unless params[:digest].present? && params[:digest] == @sample.source_digest &&
                    @sample.field_voice_id == @voice.id && @sample.source_current?
                  raise FieldVoiceSamples::Conflict, "This sample changed. Reload and retry."
                end
                FieldVoiceprints::Limits.pending!(target) unless target.id == @voice.id
                # Naming invalidates the old row. Carry the same embedded
                # audio forward as an unconfirmed candidate, never as a new
                # claim of human attribution or listening.
                replacement = FieldVoiceSample.new(account: @voice.account, field_voice: target,
                  field_recording_speaker: speaker, field_recording_id: @sample.field_recording_id,
                  speech_ms: @sample.speech_ms, profile: @sample.profile, eligible: false,
                  source_segments: @sample.source_segments, label_origin: app_token_request? ? "human" : "machine")
                replacement.vector = @sample.vector
                speaker.name_as!(target, by: current_api_user, source: app_token_request? ? "human" : "machine")
                replacement.source_digest = FieldVoiceSample.source_digest_for(speaker.reload, replacement.source_segments)
                replacement.save!
                @sample = replacement
              end
              return render json: { sample: present(@sample), message: "Source speaker corrected; this candidate requires review." }
            end
            @sample.reattribute!(voice: target, digest: params[:digest], by: app_token_request? ? current_api_user : nil)
            FieldVoices::LearnUploadJob.queue!(@sample.reload)
          else
            included = params[:included]
            unless [ true, false ].include?(included)
              return render json: { error: "Provide included: true or false." }, status: :unprocessable_entity
            end
            # An API key is machine provenance, even when owned by a person.
            # Re-inclusion of existing testimony is allowed; new testimony
            # requires the signed-in human app, never a body flag.
            if included && !@sample.manually_confirmed? && !app_token_request?
              return render json: { error: "Listen and confirm in Voices or the signed-in app. API keys cannot attest human listening." }, status: :forbidden
            end
            saved = if @sample.field_recording_speaker
              @sample.field_recording_speaker.review_sample!(sample: @sample, digest: params[:digest], by: current_api_user, included:, confirm: app_token_request?)
            else
              @sample.review!(digest: params[:digest], by: app_token_request? ? current_api_user : nil, included:)
            end
            return render json: { error: "This sample changed. Reload and listen again." }, status: :conflict unless saved
          end
          render json: { sample: present(@sample.reload) }
        end

        def destroy
          if current_api_agent
            @sample.remove!(digest: params[:digest], by: nil, unconfirmed_only: true)
            audit_resident("field_voice_sample_removed", @sample)
            return head :no_content
          end
          unless params[:digest].present? && params[:digest] == @sample.source_digest
            return render json: { error: "This sample changed. Reload and retry." }, status: :conflict
          end
          if @sample.field_recording_speaker
            speaker = @sample.field_recording_speaker
            recording = speaker.field_recording
            FieldVoiceprints::Locks.with(account: @voice.account, recording:, voices: [ @voice ]) do
              @sample.reload
              unless params[:digest] == @sample.source_digest && @sample.field_voice_id == @voice.id
                raise FieldVoiceSamples::Conflict, "This sample changed. Reload and retry."
              end
              speaker.reload.update!(sample_excluded: true, sample_review_generation: speaker.sample_review_generation + 1)
              @sample.update!(removed_at: Time.current, eligible: false)
              FieldVoiceprints::Learning.rebuild!(@voice)
            end
          else
            @sample.remove!(digest: params[:digest], by: current_api_user)
          end
          head :no_content
        end

        def audio
          unless params[:digest].present? && params[:digest] == @sample.source_digest && @sample.source_current?
            return head :conflict
          end
          bytes = if @sample.field_recording_speaker
            FieldVoiceprints::Sample.cut(@sample.field_recording_speaker.field_recording, @sample.source_segments) { |path| File.binread(path) }
          else
            @sample.audio.download
          end
          response.headers["Cache-Control"] = "private, no-store"
          send_data bytes, type: "audio/wav", disposition: "attachment", filename: "voice-sample.wav"
        rescue FieldVoiceprints::Sample::Refused, ActiveStorage::FileNotFoundError
          head :not_found
        end

        private

        # A resident re-attributes or excludes an unconfirmed uploaded
        # candidate. New inclusion is listening testimony, so it is refused;
        # the unconfirmed check runs again under the sample lock.
        def resident_update
          if request.request_parameters.key?("voice_id")
            target = @voice.account.field_voices.kept.find_by!(id: FieldVoice.decode_id(request.request_parameters["voice_id"]))
            from = @voice
            @sample.reattribute!(voice: target, digest: params[:digest], by: nil, unconfirmed_only: true)
            FieldVoices::LearnUploadJob.queue!(@sample.reload)
            audit_resident("field_voice_sample_reattributed", @sample, from_voice_id: from.id, to_voice_id: target.id)
          else
            included = params[:included]
            unless [ true, false ].include?(included)
              return render json: { error: "Provide included: true or false." }, status: :unprocessable_entity
            end
            if included
              return render json: { error: "A person must listen and confirm this sample. Residents cannot attest listening." }, status: :forbidden
            end
            saved = @sample.review!(digest: params[:digest], by: nil, included: false, unconfirmed_only: true)
            return render json: { error: "This sample changed. Reload and retry." }, status: :conflict if saved == :gone
            audit_resident("field_voice_sample_excluded", @sample)
          end
          render json: { sample: present(@sample.reload) }
        end

        def set_voice
          if request.path_parameters[:voice_id].present?
            @voice = find_actor_record!(FieldVoice.kept, request.path_parameters[:voice_id])
          else
            @sample = find_actor_record!(visible_samples(FieldVoiceSample.where(removed_at: nil)), params[:id])
            @voice = @sample.field_voice
            raise ActiveRecord::RecordNotFound unless @voice.kept?
          end
        end

        # A resident reaches only its home account (ApiHomeAccountOnly refuses
        # any other account_id); a person, any account they may act in now.
        def find_actor_record!(scope, id)
          return find_human_record!(scope, id) unless current_api_agent

          scope.where(account_id: current_api_account.id).find_by!(id: scope.klass.decode_id(id))
        rescue Hashids::InputError
          raise ActiveRecord::RecordNotFound
        end

        # Recording-backed samples carry recording audio, timings and speaker
        # ids, which residents never read; to a resident they do not exist.
        def visible_samples(scope)
          current_api_agent ? scope.where(field_recording_speaker_id: nil) : scope
        end

        # Only the signed-in human app attests a person (as before). A resident
        # key is owned by a person but never speaks as them here.
        def testimony_user
          app_token_request? && !current_api_agent ? current_api_user : nil
        end

        def audit_resident(action, sample, **data)
          return unless current_api_agent

          AuditLog.create!(user: nil, account: sample.account, action:, auditable: sample,
            data: data.merge(agent_id: current_api_agent.id, api_key_id: @current_api_key&.id, voice_id: sample.field_voice_id),
            ip_address: request.remote_ip, user_agent: request.user_agent)
        end

        def samples
          visible_samples(@voice.samples.where(removed_at: nil))
        end

        def set_sample
          @sample = samples.find_by!(id: FieldVoiceSample.decode_id(params[:id]))
        end

        def present(sample)
          row = FieldVoiceSamples::Presentation.row(sample)
          # The shared row falls back to a linked recording's date. Residents
          # never read recording metadata through this API, so they see only
          # the upload's own provenance.
          row[:recorded_at] = sample.recorded_at&.iso8601 if current_api_agent
          row.merge(
            audio_url: (audio_api_v1_field_voice_sample_path(sample.field_voice, sample, digest: sample.source_digest) if sample.source_current?))
        end

      end
    end
  end
end
