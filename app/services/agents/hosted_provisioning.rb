module Agents
  class HostedProvisioning

    class ConfigurationError < StandardError; end

    def initialize(agent:, user:)
      @agent = agent
      @user = user
    end

    def prepare!(started_at:)
      raise ConfigurationError, "Agent is not awaiting provisioning" unless agent.provisioning?
      configuration = runtime_configuration
      old_api_key = agent.outbound_api_key

      agent.transaction do
        if old_api_key
          agent.outbound_api_key = nil
          agent.outbound_api_token = nil
          agent.save! if agent.persisted?
          old_api_key.destroy!
        end

        agent.uuid ||= SecureRandom.uuid_v7
        Agents::Resources.new(agent).validate!
        agent.save! unless agent.persisted?
        outbound_api_key = ApiKey.generate_for(
          user,
          name: "agent:#{agent_slug}:outbound",
          agent: agent
        )

        agent.update!(
          outbound_api_key: outbound_api_key,
          outbound_api_token: outbound_api_key.raw_token,
          trigger_bearer_token: "tr_#{SecureRandom.hex(24)}",
          restic_password: SecureRandom.hex(32),
          container_name: LocalInstance.current.namespace ? Agents::Resources.new(agent).container : (agent.container_name.presence || Agents::Resources.new(agent).container),
          sandbox_host: configuration.fetch(:sandbox_host),
          container_image: configuration.fetch(:container_image),
          endpoint_url: configuration.fetch(:publish_ports) ? agent.endpoint_url : nil,
          runtime: "provisioning",
          provisioning_started_at: started_at,
          health_state: "unknown",
          consecutive_health_failures: 0,
          sandbox_last_error: nil,
          sandbox_last_error_at: nil
        )
      end

      agent
    end

    private

    attr_reader :agent, :user

    def runtime_configuration
      {
        sandbox_host: Agents::Config.sandbox_host,
        internal_url: Agents::Config.internal_url,
        container_image: Agents::Config.default_image,
        publish_ports: Agents::Config.publish_ports?
      }
    rescue KeyError => e
      raise ConfigurationError, "Hosted agent runtime is not configured: #{e.message}"
    end

    def agent_slug
      agent.name.to_s.parameterize.presence || "agent-#{agent.id}"
    end

  end
end
