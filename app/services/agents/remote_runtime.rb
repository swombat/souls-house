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
        "env" => environment(agent)
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
    # house origin, which is public here. Only house-funded inference runs on
    # a VM in this slice, and imported homes stay local.
    def environment(agent)
      selection = Agents::Sandbox.chaos_selection_for(agent)
      raise Unavailable, "Only house-inference residents can run on a VM" unless selection[:provider] == "house"
      raise Unavailable, "Imported homes cannot run on a VM yet" if agent.imported_home?

      origin = public_origin
      {
        "AGENT_ID" => agent.uuid,
        "AGENT_SLUG" => agent.name.to_s.parameterize.presence || agent.uuid,
        "AGENT_PROVIDER" => selection[:provider],
        "AGENT_DEFAULT_MODEL" => selection[:model],
        "TRIGGER_BEARER_TOKEN" => agent.trigger_bearer_token,
        "SOULSHOUSE_BEARER_TOKEN" => agent.outbound_api_token,
        "SOULSHOUSE_APP_URL" => origin,
        "SOULSHOUSE_ACTIVITY_ORIGIN" => origin,
        "HELIXKIT_BEARER_TOKEN" => agent.outbound_api_token,
        "HELIXKIT_APP_URL" => origin
      }.tap { |env| env["SOULSHOUSE_REQUIRE_HOUSE_TRUST"] = "1" if Agents::Config.require_house_trust? }
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
