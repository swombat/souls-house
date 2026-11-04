# Switching one of this account's connections on or off for a resident: one
# hosted here, or a guest seated here (JWblqj). A guest's switch sends a
# request to the resident's home and grants nothing until it is approved.
class Agents::ServiceAccessesController < ApplicationController

  before_action :set_agent_and_connection

  def update
    enabled = ActiveModel::Type::Boolean.new.cast(params.require(:enabled))
    if enabled && @connection.status != "connected"
      redirect_back_or_to fallback_path, alert: "Reconnect this service before enabling resident access"
      return
    end

    allowed = if guest?
      @connection.guest_access_changeable_by?(Current.user, enabled: enabled)
    else
      @connection.resident_access_changeable_by?(Current.user, enabled: enabled)
    end
    unless allowed
      message = guest? && enabled && @connection.personal? ? "Only the connection's owner can share it with a guest" : "You cannot change this resident's access"
      redirect_back_or_to fallback_path, alert: message
      return
    end

    access = @agent.set_service_access!(@connection, enabled: enabled, actor: Current.user)

    if guest?
      audit(enabled ? :share_service_with_guest : :withdraw_service_from_guest, @connection,
            resident_id: @agent.to_param, provider: @connection.provider,
            home_account_id: @agent.account_id, home_approval: access.home_approval)
      notice = if enabled
        "#{@agent.name}'s home has been asked to approve this; nothing is shared until it does"
      else
        "#{@agent.name} no longer has this connection"
      end
    else
      audit(enabled ? :enable_resident_service : :disable_resident_service,
            @connection,
            resident_id: @agent.to_param,
            provider: @connection.provider)
      notice = enabled ? "Service access will be provisioned" : "Service access will be removed"
    end
    redirect_back_or_to fallback_path, notice: notice
  rescue AgentServiceAccess::ReadGrantRefused => error
    redirect_back_or_to fallback_path, alert: error.message
  end

  private

  # Hosted residents and seated guests alike; a guest has no settings page
  # here, so its fallback is the Integrations page.
  def set_agent_and_connection
    @agent = current_account.conversation_agents.find(params[:agent_id])
    @connection = current_account.service_connections.find_by_public_id!(params[:id])
  end

  def guest?
    @agent.account_id != current_account.id
  end

  def fallback_path
    guest? ? account_integrations_path(current_account) : edit_account_agent_path(current_account, @agent, tab: "integrations")
  end

end
