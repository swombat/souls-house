module Agents
  module Config

    module_function

    def network
      if LocalInstance.current.namespace
        "#{LocalInstance.current.namespace}-agents"
      else
        ENV.fetch("SOULSHOUSE_AGENTS_NETWORK", "helixkit_agents")
      end
    end

    def default_image
      if local_development? && !LocalInstance.current.number.zero?
        LocalInstance.current.image
      else
        ENV.fetch("SOULSHOUSE_AGENT_IMAGE_DEFAULT", default_image_fallback)
      end
    end

    def default_image_fallback
      local_development? ? LocalInstance.current.image : "helixkit-agent-runtime:latest"
    end

    def internal_url
      ENV.fetch("SOULSHOUSE_AGENT_INTERNAL_URL") do
        local_development? ? "http://host.docker.internal:#{local_development_port}" : raise(KeyError, "SOULSHOUSE_AGENT_INTERNAL_URL is required")
      end
    end

    def local_development_port
      return LocalInstance.current.port(:backend).to_s if Rails.env.test?
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
      return false if LocalInstance.current.namespace
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
