module Api
  module V1
    module Field
      # The voices this Field knows, as on the Voices page (FieldVoicesController,
      # spec §7, §9): list, rename (the name changes everywhere), delete the
      # identity, forget a print, forget every print, and the account's
      # recognition setting. Forgetting is never gated.
      #
      # This is the one place the API says whether a voice is remembered (has a
      # print). It never returns a print. Remembering a voice (enrolment) needs
      # the person's own consent and stays on the page; a pending enrolment can
      # be removed with DELETE /api/v1/field/enrolments/:id.
      class VoicesController < BaseController

        include ApiHumanKey

        require_human_member
        require_api_feature_enabled :agents

        def index
          voices = current_api_account.field_voices.kept.includes(:user, :voiceprint).order(Arel.sql("lower(name)"))
          used = FieldRecordingSpeaker.where(field_voice_id: voices.map(&:id)).group(:field_voice_id).count
          render json: {
            voices: voices.map { |voice| FieldItems.voice_page_json(voice, used.fetch(voice.id, 0)) },
            members_without_voice: FieldItems.members_without_voice_json(current_api_account, except: current_api_user),
            my_voice_id: current_api_account.field_voices.kept.find_by(user: current_api_user)&.to_param,
            pending_enrolments: pending_enrolments_json,
            recognise_voices: current_api_account.recognise_voices,
            house_recognition: FieldVoiceprints.house_enabled?,
            can_change_setting: current_api_account.manageable_by?(current_api_user),
            backup_retention_days: FieldVoiceprints.backup_retention_days
          }
        end

        def update
          voice = find_voice
          if voice.update(params.permit(:name))
            render json: { voice: { id: voice.to_param, name: voice.name } }
          else
            render json: { error: voice.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        def destroy
          find_voice.delete_identity!
          head :no_content
        end

        def forget
          find_voice.forget!
          head :no_content
        end

        def forget_all
          FieldVoiceprints.forget_all!(current_api_account)
          head :no_content
        end

        # Same lock as the page: the account row, which identify and print
        # write-back also take. Off keeps stored prints, unused.
        def recognition
          unless current_api_account.manageable_by?(current_api_user)
            return render json: { error: "You don't have permission to manage this account" }, status: :forbidden
          end
          unless params.key?(:recognise_voices)
            return render json: { error: "Provide recognise_voices: true or false" }, status: :unprocessable_entity
          end

          enabled = ActiveModel::Type::Boolean.new.cast(params[:recognise_voices])
          current_api_account.with_lock { current_api_account.update!(recognise_voices: enabled) }
          render json: { recognise_voices: current_api_account.recognise_voices }
        end

        private

        def find_voice
          current_api_account.field_voices.kept.find_by!(id: FieldVoice.decode_id(params[:id]))
        end

        def pending_enrolments_json
          current_api_account.field_voice_enrolments.includes(:field_voice, field_recording_speaker: :field_recording)
            .order(:id).map do |enrolment|
              {
                id: enrolment.to_param,
                status: enrolment.status,
                voice_id: enrolment.field_voice.to_param,
                recording_id: enrolment.field_recording_speaker.field_recording.to_param,
                speaker_id: enrolment.field_recording_speaker.to_param,
                expires_at: enrolment.expires_at&.iso8601
              }
            end
        end

      end
    end
  end
end
