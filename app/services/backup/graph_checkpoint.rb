require "tempfile"

module Backup
  class GraphCheckpoint

    class Error < StandardError; end

    # A newly-created, stopped carrier uses a labelled, disposable volume. Docker
    # cp crosses the web-container/host boundary; a /tmp bind mount would not.
    def self.with_volume(agent)
      return yield([], nil) unless agent.memory_vault
      raise Error, "Graph backup requires an idle resident" if agent.agent_runtime_interactions.active.exists?
      Backup::AgentRestic.docker_environment(agent) # Enforce secondary-instance guard first.
      envelope = Mnemodyne::Checkpoint.export(agent.memory_vault)
      container = nil
      volume = "#{Agents::Resources.new(agent).container}-checkpoint-#{SecureRandom.hex(6)}"
      labels = [ *Agents::Resources.new(agent).labels, "--label", "house.souls.purpose=graph-checkpoint" ]
      volume_created = false
      begin
        capture!("docker", "volume", "create", *labels, volume)
        volume_created = true
        container = capture!("docker", "create", *labels,
          "--volume", "#{volume}:/data/memory-graph", "busybox:1.37", "true").strip
        raise Error, "Invalid graph carrier identity" unless container.match?(/\A[0-9a-f]{64}\z/)
        Tempfile.create([ "graph-checkpoint-", ".json" ]) do |file|
          file.chmod(0o600)
          file.write(JSON.generate(envelope))
          file.flush
          capture!("docker", "cp", file.path, "#{container}:/data/memory-graph/checkpoint.json")
        end
        yield [ "--volumes-from", "#{container}:ro" ], envelope
      ensure
        original_error = $!
        cleanup_error = nil
        if container&.match?(/\A[0-9a-f]{64}\z/)
          begin
            capture!("docker", "rm", "-v", container)
          rescue StandardError => error
            cleanup_error = error
            Rails.logger.error("Graph checkpoint carrier cleanup failed: container=#{container}")
          end
        end
        if volume_created
          begin
            capture!("docker", "volume", "rm", volume)
          rescue StandardError => error
            cleanup_error ||= error
            Rails.logger.error("Graph checkpoint volume cleanup failed: volume=#{volume}")
          end
        end
        raise cleanup_error if cleanup_error && !original_error
      end
    end

    def self.read(agent, snapshot)
      output = capture!("docker", "run", "--rm", *Backup::AgentRestic.docker_environment(agent),
        Backup::AgentRestic::IMAGE, "dump", snapshot.restic_snapshot_id, "/data/memory-graph/checkpoint.json")
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
      raise Error, "Invalid graph checkpoint", cause: nil
    end

    def self.capture!(*command)
      output, _error, status = Open3.capture3(*command)
      raise Error, "Graph checkpoint Docker operation failed" unless status.success?
      output
    end
    private_class_method :capture!

  end
end
