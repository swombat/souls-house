class Accounts::IntegrationsController < ApplicationController

  include IntegrationConnectionProps

  def show
    can_manage_account = current_account.service_credentials_manageable_by?(Current.user)
    service_definitions = Services::Definition.all.select(&:available?).select do |definition|
      definition.supports_management_scope?("personal") ||
        (can_manage_account && definition.supports_management_scope?("account_managed"))
    end
    agents = current_account.agents.by_name.to_a
    # Residents hosted elsewhere and seated here as guests (JWblqj). They are
    # offered beside the hosted residents, switched on by the owner (or by
    # whoever may provision an account-wide connection), and get nothing
    # until their home approves.
    guests = current_account.guest_agents.includes(:account).by_name.to_a
    connections = current_account.service_connections.account_managed
      .or(current_account.service_connections.personal.where(connected_by_user: Current.user))
      .includes(:connected_by_user).order(:id).to_a

    render inertia: "accounts/integrations", props: {
      account: current_account.as_json,
      services: service_definitions.map(&:as_json),
      focused_service: service_definitions.find { |definition| definition.key == params[:connect] }&.as_json,
      can_manage_account: can_manage_account,
      connections: integration_connections_json(connections, agents: agents, guests: guests)
    }
  end

end
