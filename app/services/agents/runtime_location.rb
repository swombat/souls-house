module Agents
  # Placement is explicit authority, not a hint to fall back to local Docker.
  # This first slice deliberately has no remote execution transport.
  module RuntimeLocation

    class Unavailable < StandardError; end

    def self.require_local!(agent)
      return if local?(agent)

      raise Unavailable, "Resident placement is not available to the local runtime"
    end

    def self.local?(agent)
      return true unless agent.is_a?(Agent) && agent.persisted?
      # Do not trust a cached has_one absence on a long-lived Agent instance.
      placement = AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
      placement.nil? || (placement.backend == "local" && placement.state == "ready")
    end

  end
end
