# Lets a resident send through a comms connection as its owner, or stops it
# (WhatsApp spec §5). Only the connection's owner can grant; anyone who can
# manage the connection can withdraw. Granting needs the resident's access
# enabled first and sending switched on for the provider
# (COMMS_SEND_PROVIDERS; otherwise 404). Every change is recorded in the
# owner's grant history (CommsSendGrantEvent) as well as the audit log.
class Agents::ServiceSendGrantsController < ApplicationController

  def update
    # Guests too: a connection here can be shared with a resident hosted
    # elsewhere, and sending through it stays the owner's to grant.
    agent = current_account.conversation_agents.find(params[:agent_id])
    connection = current_account.service_connections.find_by_public_id!(params[:service_access_id])
    raise ActiveRecord::RecordNotFound unless CommsSending.available_for?(connection)

    can_send = ActiveModel::Type::Boolean.new.cast(params.require(:can_send))
    unless connection.send_grant_changeable_by?(Current.user, can_send: can_send)
      return refuse(can_send ? "Only the connection's owner can let a resident send" : "You cannot manage this connection", :forbidden)
    end

    access = agent.agent_service_accesses.find_by(service_connection: connection)
    return refuse("Enable this resident's access first", :conflict) if access.nil?

    access.change_send_grant!(can_send, actor: Current.user)
    audit(can_send ? :grant_resident_comms_send : :withdraw_resident_comms_send, connection,
          resident_id: agent.to_param, provider: connection.provider)
    respond_to do |format|
      format.json do
        render json: { resident_id: agent.to_param, service_connection_id: connection.public_id, can_send: access.can_send?,
                       effective: access.effective?, home_approval: access.home_approval }
      end
      format.any do
        redirect_back_or_to account_integrations_path(current_account),
                            notice: send_notice(agent, access, can_send)
      end
    end
  rescue AgentServiceAccess::SendGrantRefused => error
    refuse(error.message, :conflict)
  end

  private

  # A guest's send grant is a new request to its home: it can't send yet.
  def send_notice(agent, access, can_send)
    return "#{agent.name} can no longer send" unless can_send
    return "#{agent.name} can now send as you" if access.effective?

    "Sending is waiting for approval from #{agent.name}'s home (#{agent.account.name})"
  end

  def refuse(message, status)
    respond_to do |format|
      format.json { render json: { error: message }, status: status }
      format.any { redirect_back_or_to account_integrations_path(current_account), alert: message }
    end
  end

end
