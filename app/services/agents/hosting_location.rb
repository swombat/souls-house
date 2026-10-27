module Agents
  # Where a resident's runtime lives, in words an owner can read on Settings:
  # the main house server, or its own Hetzner VM by name and size (Daniel,
  # jbaaqe 2026-10-27). Reads the placement and its one unresolved purchase;
  # never calls the provider.
  class HostingLocation

    LOCATION_NAMES = {
      "fsn1" => "Falkenstein, Germany",
      "nbg1" => "Nuremberg, Germany",
      "hel1" => "Helsinki, Finland"
    }.freeze

    def self.call(agent)
      new(agent).call
    end

    def initialize(agent)
      @agent = agent
    end

    def call
      # provisioning: a resident still being born has a home already.
      return unless @agent.externally_hosted? || @agent.provisioning?

      placement = AgentPlacement.find_by(agent_id: @agent.id)
      return { kind: "house" } if placement.nil? || placement.backend == "local"
      # A failed or retired VM placement holds no server, and the resident is
      # not on the main server either (the local runtime refuses it).
      return { kind: "none" } if placement.state.in?(%w[failed retired])

      # At most one purchase per placement is unresolved: the current server.
      operation = placement.cloud_procurement_operations.unresolved.first
      server_type = operation&.server_type
      machine = Billing::Tier::MACHINES[server_type] || {}
      location = placement.location || operation&.location

      {
        kind: "vm",
        # ready, pending (being bought and set up) or staged (an import or
        # move waiting for Activate; nothing bought yet).
        status: placement.state,
        server_type: server_type&.upcase,
        vcpus: machine[:vcpus],
        ram_gb: machine[:ram_gb],
        disk_gb: machine[:disk_gb],
        location: LOCATION_NAMES.fetch(location, location)
      }
    end

  end
end
