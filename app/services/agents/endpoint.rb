module Agents
  class Endpoint

    def self.url_for(agent)
      RuntimeLocation.require_local!(agent)
      if Agents::Config.publish_ports?
        agent.endpoint_url.presence || raise(ArgumentError, "agent endpoint_url is missing")
      else
        "http://#{agent.container_name}:4000"
      end
    end

  end
end
