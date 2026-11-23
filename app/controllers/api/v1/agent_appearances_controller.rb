module Api
  module V1
    # A resident's own colour and fallback icon, chosen by the resident: the
    # API side of the Appearance tab's pickers (AgentsController#update).
    # `GET` lists the allowed colours and icons alongside the resident's
    # current appearance so residents don't guess from VisualTag's larger
    # icon set. `PATCH` updates `colour` and/or `icon` (`null` or blank
    # clears). Resident keys only, for the key's own resident; a person who
    # can edit the resident can change either back on Appearance, the last
    # change stands, and both are audited.
    class AgentAppearancesController < BaseController

      before_action :require_resident!

      def show
        agent = current_api_agent
        render json: appearance_body(agent).merge(
          colours: Agent::VALID_COLOURS,
          icons: Agent::VALID_ICONS
        )
      end

      def update
        unless params.key?(:colour) || params.key?(:icon)
          return render_errors([ "send colour and/or icon (use null to clear)" ])
        end

        type_errors = []
        colour = normalize_choice(:colour, "Colour must be a colour name or null", type_errors)
        icon = normalize_choice(:icon, "Icon must be an icon name or null", type_errors)
        return render_errors(type_errors) if type_errors.any?

        agent = current_api_agent
        agent.colour = colour if params.key?(:colour)
        agent.icon = icon if params.key?(:icon)

        if agent.save
          audit_resident(agent)
          render json: appearance_body(agent)
        else
          messages = agent.errors.full_messages_for(:colour) + agent.errors.full_messages_for(:icon)
          render_errors(messages.presence || agent.errors.full_messages)
        end
      end

      private

      def appearance_body(agent)
        {
          colour: agent.colour,
          icon: agent.icon,
          avatar_url: agent.avatar_url
        }
      end

      def normalize_choice(field, error_message, errors)
        return nil unless params.key?(field)

        raw = params[field]
        return nil if raw.nil?

        unless raw.is_a?(String)
          errors << error_message
          return nil
        end

        raw.strip.presence
      end

      def require_resident!
        head :forbidden unless current_api_agent
      end

      def render_errors(messages)
        render json: { errors: messages }, status: :unprocessable_entity
      end

      def audit_resident(agent)
        AuditLog.create!(user: nil, account: agent.account, action: :set_agent_appearance, auditable: agent,
          data: { agent_id: agent.id, api_key_id: @current_api_key&.id, by: "resident", colour: agent.colour, icon: agent.icon },
          ip_address: request.remote_ip, user_agent: request.user_agent)
      end

    end
  end
end
