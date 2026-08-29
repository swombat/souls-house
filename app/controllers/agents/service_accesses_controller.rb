class Agents::ServiceAccessesController < ApplicationController

  before_action :set_agent_and_connection

  def update
    enabled = ActiveModel::Type::Boolean.new.cast(params.require(:enabled))
    if enabled && @connection.status != "connected"
      redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"),
                          alert: "Reconnect this service before enabling resident access"
      return
    end

    allowed = enabled ? @connection.provisionable_by?(Current.user) : @connection.manageable_by?(Current.user)
    unless allowed
      redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"),
                          alert: "You cannot change this resident's access"
      return
    end

    access = @agent.agent_service_accesses.find_or_initialize_by(service_connection: @connection)
    access.enabled = enabled
    access.follows_default = false
    access.provisioning_status = enabled ? "pending" : "removal_pending"
    access.save!

    audit(enabled ? :enable_resident_service : :disable_resident_service,
          @connection,
          resident_id: @agent.to_param,
          provider: @connection.provider)
    redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"),
                        notice: enabled ? "Service access will be provisioned" : "Service access will be removed"
  end

  private

  def set_agent_and_connection
    @agent = current_account.agents.find(params[:agent_id])
    @connection = current_account.service_connections.find_by_public_id!(params[:id])
  end

end
