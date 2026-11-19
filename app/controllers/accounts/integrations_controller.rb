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
      connections: integration_connections_json(connections, agents: agents, guests: guests),
      x_posting: x_posting_json(agents, can_manage_account)
    }
  end

  private

  # X posting is its own record (XIntegration), not a service connection,
  # so its row is drawn from this. Shown once the account has started on X;
  # connecting and the app live on the X page, the resident switches here.
  def x_posting_json(agents, can_manage)
    integration = current_account.x_integration
    return nil unless integration

    granted = integration.x_posting_grants.pluck(:agent_id).to_set
    {
      connected: integration.connected?,
      enabled: integration.enabled?,
      x_username: integration.x_username,
      media_scope_granted: integration.media_scope_granted?,
      can_manage: can_manage,
      page_url: x_integration_path(account_id: current_account.to_param),
      grant_url: grant_x_integration_path(account_id: current_account.to_param),
      residents: agents.filter_map do |agent|
        enabled = granted.include?(agent.id)
        next unless agent.offered_for_sharing?(granted: enabled)

        { id: agent.to_param, name: agent.name, active: agent.active?, enabled: enabled }
      end
    }
  end

end
