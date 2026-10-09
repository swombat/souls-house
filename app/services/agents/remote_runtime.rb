require "open3"

module Agents
  # A resident whose placement is on a house-ordered VM (#238). Rails never
  # calls the VM: everything here becomes a RunnerCommand that the VM's runner
  # polls for. Nothing falls back to local Docker.
  #
  # A remote resident is dispatchable only when all of these hold: its
  # placement is hetzner_cloud and ready, asynchronous turns are on (the
  # synchronous path would hold an HTTP request open to a VM nobody can call),
  # and the placement has a live, healthy runner enrollment.
  module RemoteRuntime

    ENDPOINT_SCHEME = "runner".freeze
    ENDPOINT_PATTERN = /\Arunner:\/\/(rnr_[0-9a-f]{20})\z/
    # Resident images are built on the house host and pushed nowhere, so a VM
    # gets one from the house by image ID (RunnerEnrollment#authorize_image!).
    IMAGE_ID = RunnerEnrollment::IMAGE_ID

    class Unavailable < StandardError; end

    module_function

    def placement_for(agent)
      return nil unless agent.is_a?(Agent) && agent.persisted?

      AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
    end

    def remote?(agent)
      placement_for(agent)&.backend == "hetzner_cloud"
    end

    # The newest enrolled, unrevoked enrollment of a ready remote placement.
    # A resident born on a VM (#246) also needs runtime_ready_at, which is set
    # only after its first verified backup: until then no user, scheduled or
    # rhythm turn can be dispatched to it, whatever state its runner is in.
    def enrollment_for(agent, now: Time.current)
      placement = placement_for(agent)
      return nil unless placement&.backend == "hetzner_cloud" && placement.state == "ready"
      return nil if placement.vm_birth? && agent.runtime_ready_at.nil?
      return nil unless ResidentTurn.enabled?

      enrollment = RunnerEnrollment.uncached do
        RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil)
          .where.not(enrolled_at: nil).order(enrolled_at: :desc).first
      end
      enrollment if enrollment&.healthy?(now:)
    end

    def dispatchable?(agent)
      enrollment_for(agent).present?
    end

    def endpoint_url(agent)
      enrollment = enrollment_for(agent) || raise(Unavailable, "Remote runtime is not ready")
      "#{ENDPOINT_SCHEME}://#{enrollment.public_id}"
    end

    def remote_endpoint?(url)
      url.to_s.start_with?("#{ENDPOINT_SCHEME}://")
    end

    # The client for a turn whose interaction was recorded against a remote
    # endpoint. The enrollment named in the endpoint must still be the live
    # one for this agent; a replaced or revoked runner gets nothing.
    def client_for(turn)
      match = ENDPOINT_PATTERN.match(turn.agent_runtime_interaction.endpoint_url.to_s)
      raise Unavailable, "Malformed remote endpoint" unless match

      enrollment = enrollment_for(turn.agent)
      raise Unavailable, "Remote runtime is not ready" unless enrollment && enrollment.public_id == match[1]

      RemoteTriggerClient.new(enrollment:, agent: turn.agent, resident_turn: turn)
    end

    # Operator action: start (or update) the resident on its VM, with the
    # exact image the house would run locally, pinned by image ID. The VM
    # fetches that image from the house and checks the ID before using it.
    def start!(agent, image: local_image_id(agent))
      raise ArgumentError, "image must be a sha256 image ID" unless IMAGE_ID.match?(image.to_s)

      enrollment = live_enrollment!(agent)
      payload = {
        "container_name" => agent.container_name,
        "image" => image,
        "memory_mb" => agent.container_memory_mb,
        "cpu_shares" => agent.container_cpu_shares,
        "env" => environment(agent),
        # External-service credentials, copied into the container before it
        # starts, as Agents::Sandbox#run_container! does locally.
        "service_manifest" => Agents::ServiceManifest.new(agent).to_yaml
      }
      RunnerCommand.enqueue!(enrollment:, kind: "start_resident", payload:)
    end

    def local_image_id(agent)
      stdout, status = Open3.capture2("docker", "image", "inspect", "--format", "{{.Id}}", agent.container_image.to_s)
      id = stdout.strip
      raise Unavailable, "resident image #{agent.container_image} is not on this host" unless status.success? && IMAGE_ID.match?(id)

      id
    end

    def stop!(agent)
      RunnerCommand.enqueue!(enrollment: live_enrollment!(agent), kind: "stop_resident",
        payload: { "container_name" => agent.container_name })
    end

    # Healthy means the runner is heartbeating and the latest lifecycle
    # command it carried out was a start.
    def healthy?(agent)
      enrollment = enrollment_for(agent)
      return false unless enrollment

      last = enrollment.commands.where(kind: %w[start_resident stop_resident]).where.not(finished_at: nil)
        .order(:finished_at, :id).last
      last&.kind == "start_resident" && last.state == "done"
    end

    # The same values Agents::Sandbox#run_container! sets locally, except the
    # house origin, which is public here: the provider and model the resident
    # runs on (house inference, an account API key, or a subscription login
    # made from inside its runtime), and the account's provider keys unless it
    # is house-funded. Imported homes are not yet seeded onto a VM.
    def environment(agent)
      raise Unavailable, "Imported homes cannot run on a VM yet" if agent.imported_home?

      origin = public_origin
      {
        "AGENT_ID" => agent.uuid,
        "AGENT_SLUG" => agent.name.to_s.parameterize.presence || agent.uuid,
        "AGENT_PROVIDER" => Agents::Sandbox.chaos_provider_for(agent),
        "AGENT_DEFAULT_MODEL" => Agents::Sandbox.chaos_model_for(agent),
        "TRIGGER_BEARER_TOKEN" => agent.trigger_bearer_token,
        "SOULSHOUSE_BEARER_TOKEN" => agent.outbound_api_token,
        "SOULSHOUSE_APP_URL" => origin,
        "SOULSHOUSE_ACTIVITY_ORIGIN" => origin,
        "HELIXKIT_BEARER_TOKEN" => agent.outbound_api_token,
        "HELIXKIT_APP_URL" => origin
      }.tap do |env|
        env["SOULSHOUSE_REQUIRE_HOUSE_TRUST"] = "1" if Agents::Config.require_house_trust?
        env.merge!(provider_keys(agent))
      end
    end

    # Agents::Sandbox#provider_env_args, for a VM: none for a house-funded
    # resident, otherwise the account's own keys.
    def provider_keys(agent)
      return {} if HouseInference::Offering.find(agent.model_id)

      agent.account.ai_provider_keys.select { |_name, value| value.present? }
    end

    # Ready and alive: the placement is ready, the runner is live, and a VM
    # birth has finished. Used to decide whether changed credentials or
    # services should restart the resident with them.
    def running?(agent)
      placement = placement_for(agent)
      return false unless placement&.backend == "hetzner_cloud" && placement.state == "ready"
      return false if placement.vm_birth? && agent.runtime_ready_at.nil?

      healthy?(agent)
    end

    # One provider-login call relayed through the runner (AgentProviderAuthClient
    # for a VM resident). The house never calls the VM, so it queues the call
    # and waits briefly for the runner's answer.
    PROVIDER_AUTH_WAIT = 25.seconds

    def provider_auth!(agent, method:, path:, params: {}, wait: PROVIDER_AUTH_WAIT, poll: 0.5)
      command = RunnerCommand.enqueue!(enrollment: live_enrollment!(agent), kind: "provider_auth", payload: {
        "container_name" => agent.container_name, "method" => method, "path" => path, "params" => params.compact
      })
      deadline = Time.current + wait
      loop do
        command.reload
        break if command.terminal?
        raise Unavailable, "The resident's server did not answer in time. Try again in a moment." if Time.current >= deadline

        sleep poll
      end
      raise Unavailable, "The resident's server could not relay that: #{command.result&.dig('error') || command.state}" unless command.state == "done"

      command.result["result"]
    end

    # The resident on a VM reaches the house the way any outside client does.
    def public_origin
      domain = ENV["SOULSHOUSE_DOMAIN"].presence || raise(Unavailable, "the house domain must be configured")
      "https://#{domain}"
    end

    def live_enrollment!(agent)
      placement = placement_for(agent)
      raise Unavailable, "Resident is not placed on a VM" unless placement&.backend == "hetzner_cloud"

      RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil).where.not(enrolled_at: nil)
        .order(enrolled_at: :desc).first || raise(Unavailable, "No enrolled runner for this placement")
    end

  end
end
