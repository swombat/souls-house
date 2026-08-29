class Accounts::PersonalServicesController < ApplicationController

  def show
    agents = current_account.agents.by_name.to_a
    connections = current_account.service_connections.personal
      .where(connected_by_user: Current.user)
      .includes(:connected_by_user)
      .to_a
    accesses = AgentServiceAccess
      .where(agent: agents, service_connection: connections)
      .index_by { |access| [ access.agent_id, access.service_connection_id ] }

    render inertia: "accounts/personal_services", props: {
      account: current_account.as_json,
      services: Services::Definition.all
        .select { |definition| definition.supports_management_scope?("personal") }
        .map(&:as_json),
      connections: connections.map do |connection|
        connection.as_connection_json(current_user: Current.user).merge(
          residents: agents.map do |agent|
            access = accesses[[ agent.id, connection.id ]]
            {
              id: agent.to_param,
              name: agent.name,
              active: agent.active?,
              enabled: access&.enabled? || false,
              provisioning_status: access&.provisioning_status,
              access_update_url: account_agent_service_access_path(current_account, agent, connection.public_id)
            }
          end
        )
      end
    }
  end

end
