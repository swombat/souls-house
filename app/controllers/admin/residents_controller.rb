# Every resident on the site, as the same cards their account sees, with
# where each one runs (this server or its own cloud VM) and whose account it
# lives in.
class Admin::ResidentsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def index
    render inertia: "admin/residents", props: {
      residents: -> { residents },
      # Light on purpose: the spinners reload these alone (ResidentSessions).
      active_sessions: -> { ResidentSessions.by_agent(Agent.all) },
      active_session_totals: -> { ResidentSessions.site_totals }
    }
  end

  private

  def residents
    accounts = Account.where(id: Agent.select(:account_id)).includes(:owner).order(:name)
    placements = AgentPlacement.where(agent_id: Agent.select(:id)).index_by(&:agent_id)
    accounts.flat_map do |account|
      owner = { account_name: account.name, owner_email: account.owner&.email_address }
      Agents::ResidentDirectory.new(account).call do |agent|
        owner.merge(hosting: hosting(placements[agent.id]))
      end
    end
  end

  # No placement, or a local one, runs in Docker on the house's own server.
  def hosting(placement)
    return { kind: "local", state: placement&.state || "ready" } if placement.nil? || placement.backend == "local"

    { kind: "cloud", state: placement.state, location: placement.location }
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
