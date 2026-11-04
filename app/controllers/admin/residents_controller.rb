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
    @operations = current_operations(placements.values)
    @prices = HouseSample.of_kind("pricing").order(sampled_at: :desc).first&.metrics&.dig("hetzner_eur_per_month")
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

    { kind: "cloud", state: placement.state, location: placement.location }.merge(machine(placement))
  end

  # The VM's type, size and monthly list price (Daniel, JOyQre 2026-11-01).
  # Type and size come from the placement's current purchase; the price is
  # the last pricing sample's gross Hetzner list price for that type in that
  # location, nil when no sample has it. Never calls the provider.
  def machine(placement)
    operation = @operations[placement.id]
    return {} unless operation

    type = operation.server_type
    location = placement.location || operation.location
    size = Billing::Tier::MACHINES[type] || {}
    price = @prices.dig(type, location) if @prices.is_a?(Hash) && location
    { server_type: type, vcpus: size[:vcpus], ram_gb: size[:ram_gb], disk_gb: size[:disk_gb],
      eur_per_month: price.is_a?(Numeric) ? price : nil }
  end

  # The purchase for the server the placement points at, else its one
  # unresolved purchase (HostingLocation's rule).
  def current_operations(placements)
    cloud = placements.reject { |placement| placement.backend == "local" }
    operations = CloudProcurementOperation.where(agent_placement_id: cloud.map(&:id)).order(id: :desc).group_by(&:agent_placement_id)
    cloud.each_with_object({}) do |placement, current|
      candidates = operations.fetch(placement.id, [])
      current[placement.id] =
        candidates.find { |operation| placement.provider_server_id && operation.provider_server_id == placement.provider_server_id } ||
        candidates.find(&:unresolved?)
    end
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
