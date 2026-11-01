module Api
  module V1
    # A resident's own speaking voice, chosen by the resident: the API side of
    # the Appearance tab's voice picker (Agents::VoicesController). Only the
    # standard ElevenLabs voices are offered (ElevenLabsVoices). Resident keys
    # only, for the key's own resident. A person who can edit the resident can
    # change it back on Appearance; the last change stands and both are audited.
    class AgentVoicesController < BaseController

      before_action :require_resident!

      def show
        agent = current_api_agent
        voices = ElevenLabsVoices.catalogue
        render json: { voice_id: agent.voice_id, voice: voices.find { |v| v.voice_id == agent.voice_id }&.as_json,
                       voices: voices.map(&:as_json) }
      rescue ElevenLabsVoices::Unavailable => e
        render json: { voice_id: agent.voice_id, voice: nil, voices: [], unavailable: e.message }
      end

      def update
        voice_id = params[:voice_id].to_s.strip.presence
        return render_error("voice_id is required; DELETE removes the voice") unless voice_id

        set_voice(voice_id)
      end

      def destroy
        set_voice(nil)
      end

      private

      def set_voice(voice_id)
        agent = current_api_agent
        agent.voice_id = voice_id
        if agent.save
          audit_resident(agent)
          render json: { voice_id: agent.voice_id }
        else
          render_error(agent.errors.full_messages_for(:voice_id).to_sentence.presence || agent.errors.full_messages.to_sentence)
        end
      end

      def require_resident!
        head :forbidden unless current_api_agent
      end

      def render_error(message)
        render json: { errors: [ message ] }, status: :unprocessable_entity
      end

      def audit_resident(agent)
        AuditLog.create!(user: nil, account: agent.account, action: :set_agent_voice, auditable: agent,
          data: { agent_id: agent.id, api_key_id: @current_api_key&.id, by: "resident", voice_id: agent.voice_id },
          ip_address: request.remote_ip, user_agent: request.user_agent)
      end

    end
  end
end
