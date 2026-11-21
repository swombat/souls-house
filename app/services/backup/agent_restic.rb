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

    # Held by a house resident's backup for as long as its container may be
    # paused, and by a runtime roll while it recreates that container (#765,
    # ops/deploy/roll-resident.rb), so neither acts on a container the other
    # is in the middle of. Advisory and keyed per resident: it holds no row,
    # so turns, heartbeats and other residents never wait on it.
    QUIESCE_LOCK = 1_936_155_243

    def self.quiesce_lock_sql(function, agent)
      "SELECT #{function}(#{QUIESCE_LOCK}, #{Integer(agent.id)})"
    end

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
    #
    # The resident's lock is taken and the pause claimed (PauseClaim) before
    # the vault's lock, outside its transaction, so the claim is committed
    # before `docker pause` and a killed worker cannot roll it back.
    def with_quiesced(agent, &block)
      Agents::Resources.new(agent).verify_existing!
      paused(agent, vault: agent.memory_vault, &block)
    end

    def under_vault(vault)
      return yield unless vault

      vault.with_lock do
        raise ArgumentError, "Erasure is pending" if vault.erasure_requested_at?
        yield
      end
    end

    # Session-level, not per transaction: a backup outlasts any transaction
    # it should hold open (a resident with a vault is inside one).
    def paused(agent, vault: nil, &block)
      connection = ActiveRecord::Base.connection
      unless connection.select_value(quiesce_lock_sql("pg_try_advisory_lock", agent))
        raise ResidentBusy, "The resident's runtime is being rolled"
      end
      begin
        paused_holding_lock(agent, vault:, &block)
      ensure
        connection.select_value(quiesce_lock_sql("pg_advisory_unlock", agent))
      end
    end

    BACKUP_LABEL = "souls.house.backup.agent"

    # Containers a backup starts for restic and the transcript check carry
    # this. It is diagnostic: an empty listing is never permission to
    # unpause.
    def backup_label(agent)
      [ "--label", "#{BACKUP_LABEL}=#{Integer(agent.id)}" ]
    end

    # A backup pauses only a running container, and claims the pause first
    # (PauseClaim, bound to the container id). Afterwards it unpauses that
    # same container and releases the claim; a claim whose unpause failed
    # is kept.
    #
    # Found paused (21 Nov 2026: a deploy killed the worker holding Mira's
    # pause, the retry backed her up paused and left her frozen for two and
    # a half hours), the pause is reported at once and never unpaused here.
    # A claim records intent, not custody: it is the same row whether the
    # earlier worker died before or after `docker pause`, so it cannot tell
    # a backup's pause from a later pause of the same container by someone
    # else, and the advisory lock does not fence a worker that lost its
    # database session (Mira, #1088). Recovery is manual
    # (docs/operations/paused-resident-recovery.md).
    # - under a claim for this very container, the claim is kept as evidence
    #   (ClaimedPause); with a labelled container still running the backup
    #   refuses as busy, otherwise it backs up as it is;
    # - with no claim for this container, the pause is not known to be a
    #   backup's (UnclaimedPause); any stale claim is dropped.
    def paused_holding_lock(agent, vault: nil)
      raise ResidentBusy, "Backup requires an idle resident" if agent.agent_runtime_interactions.active.exists?
      output, _, status = Open3.capture3("docker", "inspect", "--format", "{{.Id}} {{.State.Running}} {{.State.Paused}}", agent.container_name)
      container_id, running, paused = output.to_s.split
      claim = PauseClaim.find_by(agent_id: agent.id)
      state = "#{running} #{paused}"
      token = nil
      begin
        to_pause = nil
        if status.success? && state == "true false"
          PauseClaim.release!(agent) if claim
          to_pause = PauseClaim.claim!(agent, container_id)
        elsif status.success? && state == "true true"
          if claim&.container_id == container_id
            # Reported before the label probe, so a busy result or a Docker
            # error can't swallow the alert (Mira, #1088).
            ContainerPause.report(ContainerPause::ClaimedPause, agent,
              "is paused under an earlier backup's claim (#{claim.created_at.utc.iso8601}). A claim does not prove that backup took this pause, so the house does not unpause it")
            raise ResidentBusy, "An earlier backup's Docker work is still running" unless backup_work_finished?(agent)
          else
            PauseClaim.release!(agent) if claim
            ContainerPause.report(ContainerPause::UnclaimedPause, agent,
              "is paused and no backup claims that pause. It is not unpaused by the house")
          end
        elsif status.success? && running != "false"
          raise ArgumentError, "Cannot establish resident filesystem state"
        elsif status.success?
          PauseClaim.release!(agent) if claim
        else
          # Offline residents can have volumes but no container. Distinguish
          # absence from daemon errors through the ownership verifier above.
          raise ArgumentError, "Missing hosted runtime" if agent.external?
        end
        under_vault(vault) do
          if to_pause
            _, _, paused_ok = Open3.capture3("docker", "pause", container_id)
            raise ArgumentError, "Could not quiesce resident filesystem" unless paused_ok.success?
            token = to_pause
          end
          raise ResidentBusy, "Resident became active before checkpoint" if agent.agent_runtime_interactions.active.exists?
          yield
        end
      ensure
        PauseClaim.release!(agent, to_pause) if to_pause && token.nil?
        if token
          original_error = $!
          resumed = begin
            Open3.capture3("docker", "unpause", container_id).last.success?
          rescue StandardError
            false
          end
          unless resumed
            Rails.logger.error("Resident remains paused after backup")
            # Until 19 Nov 2026 a failed unpause was never tried again, and
            # the resident stayed frozen (Mira, 04:06-05:32Z). Now it is
            # tried once more and checked;
            # Docker not answering is never taken for unpaused. Reported
            # either way (ContainerPause). The backup's own error, if any,
            # is kept.
            outcome = ContainerPause.retry_unpause!(agent, container: container_id)
            resumed = outcome.in?(%i[unpaused not_paused])
            if !resumed && !original_error
              raise ArgumentError, "Resident remains paused after backup"
            end
          end
          PauseClaim.release!(agent, token) if resumed
        end
      end
    end

    # True only when Docker answered and no container labelled for this
    # resident's backups is running.
    def backup_work_finished?(agent)
      out, _, status = Open3.capture3("docker", "ps", "--filter", "label=#{BACKUP_LABEL}=#{Integer(agent.id)}", "--format", "{{.ID}}")
      raise ArgumentError, "Cannot establish whether backup work is still running" unless status.success?

      out.to_s.strip.empty?
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
      mounts = restored.flat_map do |name, volume|
        [ "-v", "#{volume}:/restore/data/#{name}" ]
      end
      # The Chaos journal dump comes back into a volume of its own for an
      # operator to pg_restore (docs/database-backup.md); it is never loaded
      # into a live database automatically.
      restored_dump = "#{Agents::Resources.new(agent).container}-#{ChaosJournalDump::RESTORED_VOLUME_SUFFIX}"
      mounts + [ "-v", "#{restored_dump}:/restore#{ChaosJournalDump::MOUNT}" ]
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

      present_transcript_paths(agent, volume).flat_map do |path|
        [ "--mount", "type=volume,src=#{volume},dst=/data/state/#{path},readonly,volume-subpath=#{path}" ]
      end
    end

    def present_transcript_paths(agent, volume)
      out, _, status = Open3.capture3("docker", "run", "--rm", *backup_label(agent), "--network", "none",
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
