module Agents
  module Config

    module_function

    def network
      ENV.fetch("SOULSHOUSE_AGENTS_NETWORK", "helixkit_agents")
    end

    def default_image
      ENV.fetch("SOULSHOUSE_AGENT_IMAGE_DEFAULT", default_image_fallback)
    end

    def default_image_fallback
      local_development? ? "helixkit-agent-runtime:local" : "helixkit-agent-runtime:latest"
    end

    def internal_url
      ENV.fetch("SOULSHOUSE_AGENT_INTERNAL_URL") do
        local_development? ? "http://host.docker.internal:#{local_development_port}" : raise(KeyError, "SOULSHOUSE_AGENT_INTERNAL_URL is required")
      end
    end

    def local_development_port
      ENV.fetch("SOULSHOUSE_DEV_WEB_PORT") { ENV.fetch("PORT", "3100") }
    end

    def sandbox_host
      ENV.fetch("SOULSHOUSE_SANDBOX_HOST") do
        local_development? ? "local-docker-desktop" : raise(KeyError, "SOULSHOUSE_SANDBOX_HOST is required")
      end
    end

    def publish_ports?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("SOULSHOUSE_AGENT_PUBLISH_PORTS") { local_development? })
    end

    def backups_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("SOULSHOUSE_AGENT_BACKUPS_ENABLED", !local_development?))
    end

    def cold_start?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("SOULSHOUSE_AGENT_COLD_START") { Rails.env.development? })
    end

    def restart_policy
      cold_start? ? "no" : "unless-stopped"
    end

    def local_development?
      Rails.env.development? || Rails.env.test?
    end

  end
end
