module Backup
  module AgentRestic

    IMAGE = "restic/restic:0.18.1"

    # Session transcripts are the only part of the private state volume that
    # is backed up (Daniel, 16 Nov: "they are life traces"). The rest of it
    # holds provider credentials and tokens and stays out. Each path is named
    # here, never globbed: `antigravity-cli` keeps its OAuth token beside its
    # conversations, so only the conversation directories go in. The VM
    # runner carries claude/projects the same way (host-runner/backup_proxy.py).
    TRANSCRIPT_PATHS = [
      "claude/projects",                                   # Claude Code
      "antigravity/.gemini/antigravity-cli/conversations", # agy
      "antigravity/.gemini/antigravity-cli/brain",         # agy, per conversation
      "antigravity/.chaos-conversations"                   # the agy shim's thread map
    ].freeze
    INSPECT_IMAGE = "busybox:1.37"

    # Prints "<verdict> <path>" for each path: ok, absent, link or notdir.
    TRANSCRIPT_CHECK = <<~'SH'.freeze
      for p in "$@"; do
        cur=/state; verdict=ok
        for part in $(echo "$p" | tr / ' '); do
          cur="$cur/$part"
          if [ -L "$cur" ]; then verdict=link; break; fi
          if [ ! -e "$cur" ]; then verdict=absent; break; fi
        done
        if [ "$verdict" = ok ] && [ ! -d "$cur" ]; then verdict=notdir; fi
        echo "$verdict $p"
      done
    SH

    class ResidentBusy < ArgumentError; end
    class TranscriptRefused < ArgumentError; end

    module_function

    def docker_environment(agent)
      Agents::RuntimeLocation.require_local!(agent)
      return LocalRepository.new(agent).environment if LocalRepository.enabled?
      if LocalInstance.current.namespace
        raise ArgumentError, "Remote agent backups/restores are disabled for isolated local instances"
      end
      Agents::DockerLocalGuard.check!
      [
        "-e", "AWS_ACCESS_KEY_ID=#{aws_value(:access_key_id)}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{aws_value(:secret_access_key)}",
        "-e", "AWS_DEFAULT_REGION=#{region}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{repository_url(agent)}"
      ]
    end

    def verify_archive!(agent)
      _, _, status = Open3.capture3("docker", "run", "--rm", *docker_environment(agent),
        IMAGE, "check", "--read-data")
      raise ArgumentError, "Backup archive integrity verification failed" unless status.success?
    end

    # Holds the resident still while its backup is taken: idle, and its
    # container paused (or already stopped). A resident with a memory vault is
    # also held under the vault's lock, so the graph cannot change. A resident
    # without one is paused all the same: the transcript paths are checked for
    # links inside this block, and that check means nothing while the
    # resident can still change them (Mira, #1004).
    def with_quiesced(agent, &block)
      Agents::Resources.new(agent).verify_existing!
      vault = agent.memory_vault
      return paused(agent, &block) unless vault

      vault.with_lock do
        raise ArgumentError, "Erasure is pending" if vault.erasure_requested_at?
        paused(agent, &block)
      end
    end

    def paused(agent)
      raise ResidentBusy, "Backup requires an idle resident" if agent.agent_runtime_interactions.active.exists?
      output, _, status = Open3.capture3("docker", "inspect", "--format", "{{.State.Running}} {{.State.Paused}}", agent.container_name)
      paused_here = false
      begin
        if status.success? && output.strip == "true false"
          _, _, paused = Open3.capture3("docker", "pause", agent.container_name)
          raise ArgumentError, "Could not quiesce resident filesystem" unless paused.success?
          paused_here = true
        elsif status.success? && !%w[false].include?(output.split.first) && output.strip != "true true"
          raise ArgumentError, "Cannot establish resident filesystem state"
        elsif !status.success?
          # Offline residents can have volumes but no container. Distinguish
          # absence from daemon errors through the ownership verifier above.
          raise ArgumentError, "Missing hosted runtime" if agent.external?
        end
        raise ResidentBusy, "Resident became active before checkpoint" if agent.agent_runtime_interactions.active.exists?
        yield
      ensure
        if paused_here
          original_error = $!
          begin
            _, _, resumed = Open3.capture3("docker", "unpause", agent.container_name)
            raise ArgumentError, "Resident remains paused after backup" unless resumed.success?
          rescue StandardError
            Rails.logger.error("Resident remains paused after backup")
            raise unless original_error
          end
        end
      end
    end

    def repository_url(agent)
      "s3:s3.amazonaws.com/#{bucket}/agents/#{agent.uuid}"
    end

    def backup_mounts(agent)
      backed_up_volumes(agent).flat_map do |name, volume|
        [ "-v", "#{volume}:/data/#{name}:ro" ]
      end
    end

    def restore_mounts(agent)
      # The state volume is mounted too, so transcripts in a snapshot land in
      # it. Restore recreates every volume first (AgentResticRestore#
      # recreate_volumes!), so it is empty here and nothing else in it is
      # overwritten; snapshots never carry the credentials.
      restored = backed_up_volumes(agent)
      state = Agents::VolumeSet.new(agent).names[:state]
      restored = restored.merge(state:) if state
      restored.flat_map do |name, volume|
        [ "-v", "#{volume}:/restore/data/#{name}" ]
      end
    end

    # Read-only mounts of the transcript directories that exist in the state
    # volume, each through Docker's volume-subpath. Call it only while the
    # resident is quiesced: Docker refuses a subpath link that leaves the
    # volume but follows one inside it (a claude/projects -> ../credentials
    # link would mount the credentials), so every component of every path is
    # checked here, after the pause, when the resident cannot change it. A
    # link anywhere on a path fails the backup rather than skipping the path.
    def transcript_mounts(agent)
      volume = Agents::VolumeSet.new(agent).names[:state]
      return [] if volume.blank?

      _, err, status = Open3.capture3("docker", "volume", "inspect", volume)
      unless status.success?
        return [] if err.to_s.match?(/no such volume/i)
        raise TranscriptRefused, "Cannot inspect the state volume for transcripts"
      end

      present_transcript_paths(volume).flat_map do |path|
        [ "--mount", "type=volume,src=#{volume},dst=/data/state/#{path},readonly,volume-subpath=#{path}" ]
      end
    end

    def present_transcript_paths(volume)
      out, _, status = Open3.capture3("docker", "run", "--rm", "--network", "none",
        "--mount", "type=volume,src=#{volume},dst=/state,readonly",
        INSPECT_IMAGE, "sh", "-c", TRANSCRIPT_CHECK, "transcript-check", *TRANSCRIPT_PATHS)
      raise TranscriptRefused, "Cannot inspect the state volume for transcripts" unless status.success?

      verdicts = out.to_s.lines.to_h { |line| line.strip.split(" ", 2).reverse }
      TRANSCRIPT_PATHS.select do |path|
        case verdicts[path]
        when "ok" then true
        when "absent" then false
        when "link" then raise TranscriptRefused, "Transcript path #{path} has a link on it; refusing to back up the state volume"
        else raise TranscriptRefused, "Transcript path #{path} is not a directory"
        end
      end
    end

    def backed_up_volumes(agent)
      Agents::VolumeSet.new(agent).names.except(:state)
    end

    def bucket
      ENV["RESTIC_S3_BUCKET"].presence ||
        aws_credentials[:agent_backups_bucket].presence ||
        aws_credentials[:postgres_bucket].presence ||
        raise(ArgumentError, "aws.agent_backups_bucket or aws.postgres_bucket must be configured")
    end

    def region
      return ENV["AWS_REGION"] if ENV["AWS_REGION"].present?

      if aws_credentials[:agent_backups_bucket].present?
        aws_credentials[:agent_backups_bucket_region].presence ||
          aws_credentials[:s3_region].presence ||
          "eu-west-1"
      else
        aws_credentials[:postgres_bucket_region].presence ||
          aws_credentials[:s3_region].presence ||
          "eu-west-1"
      end
    end

    def aws_value(name)
      env_name = {
        access_key_id: "AWS_ACCESS_KEY_ID",
        secret_access_key: "AWS_SECRET_ACCESS_KEY"
      }.fetch(name)

      ENV[env_name].presence || aws_credentials[name].presence ||
        raise(ArgumentError, "#{env_name} or aws.#{name} must be configured")
    end

    def aws_credentials
      Rails.application.credentials.aws || {}
    end

  end
end
