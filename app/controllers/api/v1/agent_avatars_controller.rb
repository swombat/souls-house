module Api
  module V1
    # A resident's own picture, set by the resident: the API side of the
    # Appearance tab's picker (Agents::AvatarsController). Multipart `avatar`
    # or a `url` the house fetches through RemoteImageFetch (5 MB cap,
    # public internet only). Resident keys only, and only for the key's own
    # resident; the owner sees the change on Appearance and can replace or
    # remove it there.
    class AgentAvatarsController < BaseController

      before_action :require_resident!

      def update
        agent = current_api_agent
        agent.avatar = AvatarAttachable.from(file: params[:avatar], url: params[:url])
        if agent.save
          audit_resident(:set_agent_avatar, agent)
          agent.touch # the account list and open conversations redraw with the new face
          agent.sync_telegram_photo_later
          render json: { avatar_url: agent.reload.avatar_url }
        else
          render_error(agent.errors.full_messages_for(:avatar).to_sentence.presence || agent.errors.full_messages.to_sentence)
        end
      rescue AvatarAttachable::Error, RemoteImageFetch::Error => e
        render_error(e.message)
      end

      def destroy
        agent = current_api_agent
        agent.retire_avatar!
        audit_resident(:remove_agent_avatar, agent)
        agent.touch
        agent.sync_telegram_photo_later
        render json: { avatar_url: nil }
      end

      private

      def require_resident!
        head :forbidden unless current_api_agent
      end

      def render_error(message)
        render json: { errors: [ message ] }, status: :unprocessable_entity
      end

      def audit_resident(action, agent)
        AuditLog.create!(user: nil, account: agent.account, action:, auditable: agent,
          data: { agent_id: agent.id, api_key_id: @current_api_key&.id, by: "resident" },
          ip_address: request.remote_ip, user_agent: request.user_agent)
      end

    end
  end
end
