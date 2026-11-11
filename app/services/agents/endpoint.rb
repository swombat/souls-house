module Agents
  class Endpoint

    def self.url_for(agent)
      # A resident on a VM has no URL the house can call; its turns go
      # through the runner's command channel (Agents::RemoteRuntime).
      # A remote placement never reaches the local check (#868): when it
      # can't take a turn, RemoteRuntime says why.
      if RemoteRuntime.remote?(agent)
        RemoteRuntime.require_dispatchable!(agent)
        return RemoteRuntime.endpoint_url(agent)
      end

      RuntimeLocation.require_local!(agent)
      if Agents::Config.publish_ports?
        agent.endpoint_url.presence || raise(ArgumentError, "agent endpoint_url is missing")
      else
        "http://#{agent.container_name}:4000"
      end
    end

  end
end
