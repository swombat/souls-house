module Api
  module V1
    module Field
      # Naming a speaker on one recording, as on the transcript page
      # (FieldRecordingSpeakersController). Exactly one way per request:
      #
      #   me: true               your own voice (made on first use)
      #   voice_id: <id>         an existing voice in this account
      #   member_user_id: <id>   an account member who has no voice yet
      #   name: "Priya"          a new voice; if a voice of that name exists,
      #                          409 asks "same Priya?" unless link_existing
      #   unname: true           back to "Speaker N"
      #
      # Confirming or dismissing a suggestion or a voice recognition isn't
      # here: those answer biometric and inferred data the API doesn't show.
      class SpeakersController < BaseController

        include ApiHumanReach

        before_action :require_human_actor!
        require_api_feature_enabled :agents

        def update
          speaker = find_speaker
          attributes = params.permit(:me, :voice_id, :member_user_id, :name, :link_existing, :unname)

          if truthy?(attributes[:unname])
            speaker.unname!
          else
            choice = FieldVoice::Choice.resolve(
              account: speaker.field_recording.account, user: current_api_user,
              me: truthy?(attributes[:me]), voice_id: attributes[:voice_id],
              member_user_id: attributes[:member_user_id], name: attributes[:name],
              link_existing: truthy?(attributes[:link_existing])
            )
            return render_match(choice.match) if choice.match
            return render json: { error: "Choose who this is." }, status: :unprocessable_entity unless choice.voice

            speaker.name_as!(choice.voice, by: current_api_user)
          end

          render json: { speaker: FieldItems.plain_speaker_json(speaker.reload) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end

        private

        def find_speaker
          recording = find_human_record!(FieldRecording.kept, params[:recording_id])
          # Association finders decode with the owner's salt, so decode explicitly.
          recording.speakers.find_by!(id: FieldRecordingSpeaker.decode_id(params[:id]))
        end

        def render_match(voice)
          render json: {
            error: "A voice named #{voice.name} already exists. Send link_existing: true to use it, or another name.",
            match: { voice_id: voice.to_param, name: voice.name, last_named_in: voice.last_named_in&.title }
          }, status: :conflict
        end

        def truthy?(value) = ActiveModel::Type::Boolean.new.cast(value) == true

      end
    end
  end
end
