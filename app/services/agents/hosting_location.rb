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
      return unless @agent.externally_hosted?

      placement = AgentPlacement.find_by(agent_id: @agent.id)
      return { kind: "house" } if placement.nil? || placement.backend == "local"

      # At most one purchase per placement is unresolved: the current server.
      operation = placement.cloud_procurement_operations.unresolved.first
      server_type = operation&.server_type
      machine = Billing::Tier::MACHINES[server_type] || {}
      location = placement.location || operation&.location

      {
        kind: "vm",
        ready: placement.state == "ready",
        server_type: server_type&.upcase,
        vcpus: machine[:vcpus],
        ram_gb: machine[:ram_gb],
        disk_gb: machine[:disk_gb],
        location: LOCATION_NAMES.fetch(location, location)
      }
    end

  end
end
