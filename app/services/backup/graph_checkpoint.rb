require "tempfile"

module Backup
  class GraphCheckpoint

    class Error < StandardError; end

    # A newly-created, stopped carrier container owns an anonymous volume. Docker
    # cp crosses the web-container/host boundary; a /tmp bind mount would not.
    def self.with_volume(agent)
      return yield([], nil) unless agent.memory_vault
      raise Error, "Graph backup requires an idle resident" if agent.agent_runtime_interactions.active.exists?
      Backup::AgentRestic.docker_environment(agent) # Enforce secondary-instance guard first.
      envelope = Mnemodyne::Checkpoint.export(agent.memory_vault)
      container = nil
      begin
        container = capture!("docker", "create", "--label", "house.souls.purpose=graph-checkpoint",
          "--volume", "/data/memory-graph", "busybox:1.37", "true").strip
        raise Error, "Invalid graph carrier identity" unless container.match?(/\A[0-9a-f]{64}\z/)
        Tempfile.create([ "graph-checkpoint-", ".json" ]) do |file|
          file.chmod(0o600)
          file.write(JSON.generate(envelope))
          file.flush
          capture!("docker", "cp", file.path, "#{container}:/data/memory-graph/checkpoint.json")
        end
        yield [ "--volumes-from", "#{container}:ro" ], envelope
      ensure
        if container&.match?(/\A[0-9a-f]{64}\z/)
          capture!("docker", "rm", "-v", container)
        end
      end
    end

    def self.read(agent, snapshot)
      output = capture!("docker", "run", "--rm", *Backup::AgentRestic.docker_environment(agent),
        "restic/restic:latest", "dump", snapshot.restic_snapshot_id, "/data/memory-graph/checkpoint.json")
      raise Error, "Graph checkpoint too large" if output.bytesize > Mnemodyne::Checkpoint::MAX_BYTES
      envelope = JSON.parse(output)
      raise Error, "Invalid graph checkpoint" unless envelope.is_a?(Hash) && envelope["payload"].is_a?(Hash)
      expected = snapshot.graph_checkpoint_digest
      unless expected.present? && envelope["sha256"] == expected &&
          Digest::SHA256.hexdigest(JSON.generate(envelope.fetch("payload"))) == expected &&
          envelope.dig("payload", "resident_uuid") == agent.uuid &&
          envelope.dig("payload", "version") == Mnemodyne::Checkpoint::VERSION
        raise Error, "Graph checkpoint does not match this resident backup"
      end
      envelope
    rescue JSON::ParserError, KeyError, TypeError
      raise Error, "Invalid graph checkpoint"
    end

    def self.capture!(*command)
      output, _error, status = Open3.capture3(*command)
      raise Error, "Graph checkpoint Docker operation failed" unless status.success?
      output
    end
    private_class_method :capture!

  end
end
