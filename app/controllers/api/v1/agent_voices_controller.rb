module Api
  module V1
    # A resident's own speaking voice, chosen by the resident: the API side of
    # the Appearance tab's voice picker (Agents::VoicesController). The
    # standard ElevenLabs voices are offered, and the account's own library
    # when it has an ElevenLabs key of its own (ElevenLabsVoices). Resident keys
    # only, for the key's own resident. A person who can edit the resident can
    # change it back on Appearance; the last change stands and both are audited.
    class AgentVoicesController < BaseController

      before_action :require_resident!

      def show
        agent = current_api_agent
        body = { voice_id: agent.voice_id }
        voices = read_list(body, :voices, :unavailable) { ElevenLabsVoices.catalogue }
        library = read_list(body, :library_voices, :library_unavailable) { ElevenLabsVoices.library(agent.account) }
        body[:voice] = (voices + library).find { |v| v.voice_id == agent.voice_id }&.as_json
        body.merge!(delivery_body(agent))
        render json: body.slice(:voice_id, :voice, :voices, :unavailable, :library_voices, :library_unavailable,
          :delivery, :delivery_override)
      end

      # How the voice is read aloud (VoiceDelivery): GET shows the effective
      # values and the override that produced them; PUT replaces the override
      # with exactly the fields given; DELETE restores the house defaults.
      def show_delivery
        render json: delivery_body(current_api_agent)
      end

      def update_delivery
        agent = current_api_agent
        unless params.key?(:delivery)
          return render(json: { errors: [ 'send {"delivery": {...}}; DELETE restores the defaults' ] }, status: :unprocessable_entity)
        end

        input = params[:delivery]
        input = input.to_unsafe_h if input.respond_to?(:to_unsafe_h)
        set_delivery(agent, VoiceDelivery.normalize!(input))
      rescue VoiceDelivery::Invalid => e
        render json: { errors: e.errors }, status: :unprocessable_entity
      end

      def destroy_delivery
        set_delivery(current_api_agent, nil)
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

      def read_list(body, field, unavailable_field)
        list = yield
        body[field] = list.map(&:as_json)
        list
      rescue ElevenLabsVoices::Unavailable => e
        body[field] = []
        body[unavailable_field] = e.message
        []
      end

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

      def delivery_body(agent)
        delivery = agent.speech_delivery
        { delivery: delivery.as_json, delivery_override: agent.voice_delivery, delivery_summary: delivery.summary }
      end

      def set_delivery(agent, stored)
        agent.voice_delivery = stored
        if agent.save
          AuditLog.create!(user: nil, account: agent.account, action: :set_agent_voice, auditable: agent,
            data: { agent_id: agent.id, api_key_id: @current_api_key&.id, by: "resident", voice_delivery: agent.voice_delivery },
            ip_address: request.remote_ip, user_agent: request.user_agent)
          render json: delivery_body(agent)
        else
          render json: { errors: agent.errors.full_messages_for(:voice_delivery) }, status: :unprocessable_entity
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
