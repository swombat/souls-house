module Agents
  # Placement is explicit authority, not a hint to fall back to local Docker.
  # A remote placement runs only through Agents::RemoteRuntime (#238), and
  # only when that says it is ready; nothing here falls back to local.
  module RuntimeLocation

    class Unavailable < StandardError; end

    def self.require_local!(agent)
      return if local?(agent)

      raise Unavailable, "Resident placement is not available to the local runtime"
    end

    # Turns may be admitted for this resident: local, or ready on its VM.
    def self.dispatchable?(agent)
      return false if Backup::VmResident.held?(agent)
      local?(agent) || Agents::RemoteRuntime.dispatchable?(agent)
    end

    def self.local?(agent)
      return true unless agent.is_a?(Agent) && agent.persisted?
      # Do not trust a cached has_one absence on a long-lived Agent instance.
      placement = AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
      placement.nil? || (placement.backend == "local" && placement.state == "ready")
    end

  end
end
