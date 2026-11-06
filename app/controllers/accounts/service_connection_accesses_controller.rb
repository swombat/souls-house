# The step a new integration lands on (YgDZGe): it is connected, and nobody
# can use it until a resident is switched on. The same switches as the
# Integrations card, on their own, with a way back.
class Accounts::ServiceConnectionAccessesController < ApplicationController

  include IntegrationConnectionProps

  def show
    connection = visible_connections.find_by_public_id!(params[:service_connection_id])
    agents = current_account.agents.by_name.to_a
    guests = current_account.guest_agents.includes(:account).by_name.to_a

    render inertia: "accounts/connection_access", props: {
      account: current_account.as_json,
      connection: integration_connections_json([ connection ], agents: agents, guests: guests).first,
      integrations_url: account_integrations_path(current_account)
    }
  end

  private

  # Same visibility as the Integrations page.
  def visible_connections
    current_account.service_connections.account_managed
      .or(current_account.service_connections.personal.where(connected_by_user: Current.user))
  end

end
