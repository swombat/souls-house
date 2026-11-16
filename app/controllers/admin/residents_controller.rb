# Every resident on the site, as the same cards their account sees, with
# where each one runs (this server or its own cloud VM) and whose account it
# lives in.
class Admin::ResidentsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def index
    render inertia: "admin/residents", props: {
      residents: -> { residents },
      empty_vms: -> { empty_vms },
      # Light on purpose: the spinners reload these alone (ResidentSessions).
      active_sessions: -> { ResidentSessions.by_agent(Agent.all) },
      active_session_totals: -> { ResidentSessions.site_totals }
    }
  end

  private

  # Servers the house holds at Hetzner, and so pays for, with no resident on
  # them (Daniel, JWbKBj 2026-11-16): a spare not yet taken, a resident's old
  # server kept after a move, a server kept after its resident was rolled
  # back to the house, or a resident's purchase whose placement now points at
  # another server. A purchase counts once the provider has given it a
  # server and until its deletion is verified. Read from the house's own
  # records; never calls the provider, so a server bought outside the house
  # is not here.
  def empty_vms
    operations = CloudProcurementOperation.unresolved.where.not(provider_server_id: nil)
      .includes(agent_placement: :agent).order(:created_at)
    operations.filter_map do |operation|
      reason = empty_reason(operation)
      next unless reason

      size = Billing::Tier::MACHINES[operation.server_type] || {}
      price = prices.dig(operation.server_type, operation.location) if prices.is_a?(Hash)
      { id: operation.id, reason:, state: operation.state, server_type: operation.server_type,
        location: operation.location, provider_server_id: operation.provider_server_id,
        label: operation.provider_placement_label, since: operation.created_at.iso8601,
        vcpus: size[:vcpus], ram_gb: size[:ram_gb], disk_gb: size[:disk_gb],
        eur_per_month: price.is_a?(Numeric) ? price : nil }
    end
  end

  def empty_reason(operation)
    case operation.purpose
    when "spare" then "spare"
    when "move_source" then "moved_off"
    else
      placement = operation.agent_placement
      return "resident_gone" if placement.nil? || placement.agent.nil?
      # Rollback#switch! makes the placement local and clears its server id
      # but keeps the server until release. A placement only ever buys while
      # it is a cloud one (VmMigration stages it hetzner_cloud first), so a
      # local placement with a bought server is that leftover; a cloud one
      # with no server id yet is still being bought, not empty (Mira, #993).
      return "rolled_back" if placement.backend == "local"
      return "replaced" if placement.provider_server_id.present? && placement.provider_server_id != operation.provider_server_id

      nil
    end
  end

  def prices
    return @prices if defined?(@prices)

    @prices = HouseSample.of_kind("pricing").order(sampled_at: :desc).first&.metrics&.dig("hetzner_eur_per_month")
  end

  def residents
    accounts = Account.where(id: Agent.select(:account_id)).includes(:owner).order(:name)
    placements = AgentPlacement.where(agent_id: Agent.select(:id)).index_by(&:agent_id)
    @operations = current_operations(placements.values)
    @kernels = kernels(placements.values)
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

    kernel = @kernels[placement.id]
    { kind: "cloud", state: placement.state, location: placement.location }
      .merge(kernel ? { kernel: } : {}).merge(machine(placement))
  end

  # Running vs installed kernel, from the live runner's last heartbeat
  # (KernelReboot). nil for a runner that doesn't report it.
  def kernels(placements)
    cloud = placements.reject { |placement| placement.backend == "local" }.map(&:id)
    RunnerEnrollment.where(agent_placement_id: cloud, revoked_at: nil).where.not(enrolled_at: nil)
      .order(:enrolled_at).each_with_object({}) do |enrollment, kernels|
        facts = KernelReboot.facts_of(enrollment)
        next unless facts["kernel_running"]

        kernels[enrollment.agent_placement_id] = {
          running: facts["kernel_running"], installed: facts["kernel_installed"],
          reboot_required: facts["reboot_required"] == true
        }
      end
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
    price = prices.dig(type, location) if prices.is_a?(Hash) && location
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
