module Agents
  class HostedProvisioning

    class ConfigurationError < StandardError; end

    def initialize(agent:, user:)
      @agent = agent
      @user = user
    end

    def prepare!(started_at:)
      raise ConfigurationError, "Agent is not awaiting provisioning" unless agent.provisioning?
      return prepare_remote!(started_at:) if Agents::RemoteRuntime.remote?(agent)

      configuration = runtime_configuration
      old_api_key = agent.outbound_api_key

      agent.transaction do
        discard_outbound_key!(old_api_key)

        agent.uuid ||= SecureRandom.uuid_v7
        Agents::Resources.new(agent).validate!
        agent.save! unless agent.persisted?
        outbound_api_key = mint_outbound_key!

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

    # A resident placed on its own VM (#238) gets the same credentials a
    # local one does, and nothing that belongs to local Docker: no sandbox
    # host, no published port, no Resources check (which rightly refuses a
    # remote placement). Its container name is derived the same way, but it
    # names a container on the VM, created by the runner's start_resident.
    # The image is recorded so RemoteRuntime.start! can pin its ID.
    def prepare_remote!(started_at:)
      image = begin
        Agents::Config.default_image
      rescue KeyError => e
        raise ConfigurationError, "Hosted agent runtime is not configured: #{e.message}"
      end
      old_api_key = agent.outbound_api_key

      agent.transaction do
        discard_outbound_key!(old_api_key)
        agent.uuid ||= SecureRandom.uuid_v7
        outbound_api_key = mint_outbound_key!

        agent.update!(
          outbound_api_key: outbound_api_key,
          outbound_api_token: outbound_api_key.raw_token,
          trigger_bearer_token: "tr_#{SecureRandom.hex(24)}",
          restic_password: agent.restic_password.presence || SecureRandom.hex(32),
          container_name: "hk-agent-#{agent.uuid}",
          sandbox_host: nil,
          container_image: image,
          endpoint_url: nil,
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

    def discard_outbound_key!(old_api_key)
      return unless old_api_key

      agent.outbound_api_key = nil
      agent.outbound_api_token = nil
      agent.save! if agent.persisted?
      old_api_key.destroy!
    end

    def mint_outbound_key!
      ApiKey.generate_for(user, name: "agent:#{agent_slug}:outbound", agent: agent)
    end

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
