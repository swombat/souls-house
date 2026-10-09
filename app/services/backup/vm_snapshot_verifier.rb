require "open3"
require "timeout"

module Backup
  # Restic snapshot objects are encrypted. S3 presence alone cannot establish
  # tags or checkpoint content: the house decrypts them with restic, reading
  # its repository directly and never trusting runner-supplied JSON.
  class VmSnapshotVerifier

    class Invalid < StandardError; end
    LIMIT = Mnemodyne::Checkpoint::MAX_BYTES + 1.megabyte
    TIMEOUT = 120

    def initialize(capture: nil)
      @capture = capture
    end

    def verify!(agent:, snapshot_id:, checkpoint_digest:, checkpoint_file_digest:)
      raise Invalid, "Invalid snapshot identity" unless snapshot_id.to_s.match?(/\A[0-9a-f]{64}\z/)
      snapshots = JSON.parse(capture(agent, "snapshots", snapshot_id, "--json"))
      snapshot = snapshots.find { |item| item["id"] == snapshot_id } if snapshots.is_a?(Array)
      unless snapshot && snapshot["tags"].is_a?(Array) && snapshot["tags"].include?("agent_id=#{agent.uuid}")
        raise Invalid, "Snapshot is missing or belongs to another resident"
      end
      checkpoint_json = capture(agent, "dump", snapshot_id, "/data/memory-graph/checkpoint.json")
      unless Digest::SHA256.hexdigest(checkpoint_json) == checkpoint_file_digest
        raise Invalid, "Stored checkpoint bytes do not match the issued envelope"
      end
      envelope = JSON.parse(checkpoint_json)
      if checkpoint_digest
        unless envelope.is_a?(Hash) && envelope["sha256"] == checkpoint_digest &&
            envelope.dig("payload", "resident_uuid") == agent.uuid &&
            envelope.dig("payload", "version") == Mnemodyne::Checkpoint::VERSION &&
            Digest::SHA256.hexdigest(JSON.generate(envelope.fetch("payload"))) == checkpoint_digest
          raise Invalid, "Stored graph checkpoint is invalid"
        end
      elsif !envelope.nil?
        raise Invalid, "Unexpected graph checkpoint"
      end
      true
    rescue JSON::ParserError, KeyError, TypeError
      raise Invalid, "Malformed snapshot or checkpoint", cause: nil
    end

    private

    def capture(agent, *args)
      return @capture.call(agent, *args) if @capture
      # No production credential lookup or Docker operation in ordinary tests.
      raise Invalid, "Live VM backup verification is disabled in tests" if Rails.env.test?
      raise Invalid, "Verification requires a VM placement" unless Agents::RemoteRuntime.remote?(agent)
      name = "vm-backup-check-#{SecureRandom.hex(12)}"
      environment = [
        "-e", "AWS_ACCESS_KEY_ID=#{AgentRestic.aws_value(:access_key_id)}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{AgentRestic.aws_value(:secret_access_key)}",
        "-e", "AWS_DEFAULT_REGION=#{AgentRestic.region}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{AgentRestic.repository_url(agent)}"
      ]
      argv = [ "docker", "run", "--rm", "--name", name, *environment,
        AgentRestic::IMAGE, "--no-lock", "--no-cache", *args ]
      output = +"".b
      Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, thread|
        stdin.close
        reader = Thread.new do
          loop do
            chunk = stdout.readpartial(64.kilobytes)
            output << chunk
            raise Invalid, "Verification output exceeds limit" if output.bytesize > LIMIT
          end
        rescue EOFError
          nil
        end
        errors = Thread.new { IO.copy_stream(stderr, File::NULL) }
        begin
          Timeout.timeout(TIMEOUT) do
            reader.value
            errors.value
            raise Invalid, "Cannot read backup repository" unless thread.value.success?
          end
        ensure
          if thread.alive?
            Process.kill("KILL", -thread.pid) rescue nil
          end
          reader.join
          errors.join
        end
      end
      output.force_encoding(Encoding::UTF_8)
    rescue Timeout::Error
      raise Invalid, "Backup verification timed out", cause: nil
    ensure
      # Removing by a unique name also stops a Docker container after killing
      # the client; a remote daemon is not contained by killing its CLI.
      cleanup(name) if name
    end

    def cleanup(name)
      pid = Process.spawn("docker", "rm", "--force", name,
        out: File::NULL, err: File::NULL, pgroup: true)
      begin
        Timeout.timeout(10) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("KILL", -pid) rescue nil
        Process.wait(pid) rescue nil
        raise Invalid, "Verification container cleanup timed out", cause: nil
      end
    end

  end
end
