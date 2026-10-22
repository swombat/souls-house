module Api
  module V1
    module Field
      # The voices this Field knows, as on the Voices page (FieldVoicesController,
      # spec §7, §9): list, rename (the name changes everywhere), delete the
      # identity, forget a voice, remember it again, forget every voice, and the
      # account's recognition setting. Forgetting is never gated.
      #
      # This is the one place the API says whether a voice is remembered (has a
      # print). It never returns a print or a sample.
      #
      # A resident lists and resolves its home account's voices (id, name,
      # member) so it can upload candidate samples to them. Creating, renaming,
      # deleting, forgetting and the recognition setting stay a person's.
      class VoicesController < BaseController

        include ApiHumanReach
        include ApiHomeAccountOnly

        before_action :require_human_actor!, except: %i[index resolve]
        require_api_feature_enabled :agents

        def index
          if current_api_agent
            voices = current_api_account.field_voices.kept.order(Arel.sql("lower(name)"))
            return render json: { voices: voices.map { |voice| { id: voice.to_param, name: voice.name, member: voice.user_id.present? } } }
          end

          account = human_request_account!
          voices = account.field_voices.kept.includes(:user, :voiceprint).order(Arel.sql("lower(name)"))
          used = FieldRecordingSpeaker.where(field_voice_id: voices.map(&:id)).group(:field_voice_id).count
          active_ids = FieldVoiceprints::Identification.active_prints(account).map(&:id)
          render json: {
            voices: voices.map { |voice| FieldItems.voice_page_json(voice, used.fetch(voice.id, 0), active_ids) },
            members_without_voice: FieldItems.members_without_voice_json(account, except: current_api_user),
            my_voice_id: account.field_voices.kept.find_by(user: current_api_user)&.to_param,
            recognise_voices: account.recognise_voices,
            house_recognition: FieldVoiceprints.house_enabled?,
            voice_conversion: FieldVoiceprints::Conversion.presentation(account),
            can_change_setting: account.manageable_by?(current_api_user)
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

        def create
          account = human_request_account!
          voice = account.with_lock do
            account.field_voices.create!(name: params[:name], created_by: current_api_user)
          end
          render json: { voice: { id: voice.to_param, name: voice.name } }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "A voice with this name already exists. Resolve it explicitly." }, status: :conflict
        end

        # Lookup never creates or silently merges identities.
        def resolve
          account = current_api_agent ? current_api_account : human_request_account!
          voice = account.field_voices.kept.named_like(params[:name]).first!
          render json: { voice: { id: voice.to_param, name: voice.name } }
        end

        def destroy
          find_voice.delete_identity!
          head :no_content
        end

        def forget
          find_voice.forget!
          head :no_content
        end

        def remember
          find_voice.remember_again!
          head :no_content
        end

        def forget_all
          FieldVoiceprints.forget_all!(human_request_account!)
          head :no_content
        end

        # Same lock as the page: the account row, which learning and matching
        # also take. Off keeps what was learned, unused.
        def recognition
          account = human_request_account!
          unless account.manageable_by?(current_api_user)
            return render json: { error: "You don't have permission to manage this account" }, status: :forbidden
          end
          unless params.key?(:recognise_voices)
            return render json: { error: "Provide recognise_voices: true or false" }, status: :unprocessable_entity
          end

          enabled = ActiveModel::Type::Boolean.new.cast(params[:recognise_voices])
          account.with_lock { account.update!(recognise_voices: enabled) }
          render json: { recognise_voices: account.recognise_voices }
        end

        private

        def find_voice
          find_human_record!(FieldVoice.kept, params[:id])
        end

      end
    end
  end
end
