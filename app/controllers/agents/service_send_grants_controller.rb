# Lets a resident send through a comms (WhatsApp) connection as its owner,
# or stops it (spec §5). Only the connection's owner can grant; anyone who
# can manage the connection can withdraw. Granting needs the resident's
# access enabled first, and every change is recorded in the owner's grant
# history (CommsSendGrantEvent) as well as the audit log.
class Agents::ServiceSendGrantsController < ApplicationController

  def update
    agent = current_account.agents.find(params[:agent_id])
    connection = current_account.service_connections.find_by_public_id!(params[:service_access_id])
    can_send = ActiveModel::Type::Boolean.new.cast(params.require(:can_send))
    unless connection.send_grant_changeable_by?(Current.user, can_send: can_send)
      return refuse(agent, can_send ? "Only the connection's owner can let a resident send" : "You cannot manage this connection", :forbidden)
    end

    access = agent.agent_service_accesses.find_by(service_connection: connection)
    return refuse(agent, "Enable this resident's access first", :conflict) if access.nil?

    access.change_send_grant!(can_send, actor: Current.user)
    audit(can_send ? :grant_resident_comms_send : :withdraw_resident_comms_send, connection,
          resident_id: agent.to_param, provider: connection.provider)
    respond_to do |format|
      format.json { render json: { resident_id: agent.to_param, service_connection_id: connection.public_id, can_send: access.can_send? } }
      format.any do
        redirect_back_or_to account_integrations_path(current_account),
                            notice: can_send ? "#{agent.name} can now send as you" : "#{agent.name} can no longer send"
      end
    end
  rescue AgentServiceAccess::SendGrantRefused => error
    refuse(agent, error.message, :conflict)
  end

  private

  def refuse(agent, message, status)
    respond_to do |format|
      format.json { render json: { error: message }, status: status }
      format.any { redirect_back_or_to account_integrations_path(current_account), alert: message }
    end
  end

end
