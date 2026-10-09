class Accounts::IntegrationsController < ApplicationController

  def show
    can_manage_account = current_account.service_credentials_manageable_by?(Current.user)
    service_definitions = Services::Definition.all.select do |definition|
      definition.supports_management_scope?("personal") ||
        (can_manage_account && definition.supports_management_scope?("account_managed"))
    end
    agents = current_account.agents.by_name.to_a
    connections = current_account.service_connections.account_managed
      .or(current_account.service_connections.personal.where(connected_by_user: Current.user))
      .includes(:connected_by_user).order(:id).to_a
    accesses = AgentServiceAccess
      .where(agent: agents, service_connection: connections)
      .index_by { |access| [ access.agent_id, access.service_connection_id ] }

    render inertia: "accounts/integrations", props: {
      account: current_account.as_json,
      services: service_definitions.map(&:as_json),
      focused_service: service_definitions.find { |definition| definition.key == params[:connect] }&.as_json,
      can_manage_account: can_manage_account,
      connections: connections.map do |connection|
        tailnet_visible = tailnet_visible?(connection)
        connection.as_connection_json(current_user: Current.user).merge(
          can_delegate: connection.owner?(Current.user),
          residents: agents.map do |agent|
            access = accesses[[ agent.id, connection.id ]]
            {
              id: agent.to_param,
              name: agent.name,
              active: agent.active?,
              enabled: access&.enabled? || false,
              provisioning_status: access&.provisioning_status,
              access_update_url: account_agent_service_access_path(current_account, agent, connection.public_id),
              # Each granted resident is its own node and joins by its own
              # sign-in; the account screen shows every one of them in one place.
              tailnet_url: (account_agent_tailnet_path(current_account, agent) if tailnet_visible && access&.enabled?),
              integrations_url: (edit_account_agent_path(current_account, agent, tab: "integrations") if tailnet_visible)
            }
          end
        )
      end
    }
  end

  private

  # Same rule as Agents::TailnetsController, which the panel calls.
  def tailnet_visible?(connection)
    connection.provider == "tailscale" && connection.status == "connected" &&
      (connection.provisionable_by?(Current.user) || connection.manageable_by?(Current.user))
  end

end
