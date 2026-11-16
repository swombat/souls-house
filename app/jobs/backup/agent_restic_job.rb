module Backup
  class AgentResticJob < ApplicationJob

    queue_as :default

    def perform(agent_id, force: false)
      return unless force || Agents::Config.backups_enabled?

      agent = Agent.find(agent_id)
      return unless agent.externally_hosted?
      # A disabled account's residents are not backed up, even when the job
      # was queued before the disable or forced: their servers are being
      # deleted and nothing of theirs should start.
      return if agent.account.disabled?
      if Agents::RemoteRuntime.remote?(agent)
        return VmResident.issue!(placement: Agents::RemoteRuntime.placement_for(agent))
      end

      if agent.memory_vault && agent.agent_runtime_interactions.active.exists?
        raise Backup::AgentRestic::ResidentBusy, "Backup requires an idle resident"
      end
      init_restic_repo!(agent)
      backup_started_at = Time.current
      checkpoint = nil
      snapshot_id, size, duration_ms, ok, stderr_tail = Backup::AgentRestic.with_quiesced(agent) do
        # Inside the pause: the transcript paths are checked for links when
        # the resident can no longer change them.
        transcripts = Backup::AgentRestic.transcript_mounts(agent)
        # The Chaos journal is dumped inside the pause too, so it matches the
        # files it is snapshotted with.
        Backup::ChaosJournalDump.with_volume(agent) do |journal, _receipt|
          Backup::GraphCheckpoint.with_volume(agent) do |mounts, envelope|
            checkpoint = envelope
            run_restic_backup(agent, graph_mounts: mounts + transcripts + journal)
          end
        end
      end
      if checkpoint && agent.agent_runtime_interactions.where("started_at >= ?", backup_started_at).exists?
        ok = false
        stderr_tail = "Resident activity overlapped graph/identity backup; retry while idle"
      end
      snapshot = AgentBackupSnapshot.create!(
        agent: agent,
        graph_checkpoint_digest: checkpoint&.fetch("sha256"),
        graph_schema_version: checkpoint && Mnemodyne::Checkpoint::VERSION,
        restic_snapshot_id: snapshot_id.presence || "unknown",
        size_bytes: size,
        taken_at: Time.current,
        duration_ms: duration_ms,
        ok: ok,
        stderr_tail: stderr_tail
      )
      if ok
        record_prune_failure(snapshot, prune!(agent))
        record_prune_failure(snapshot, fit!(agent))
      end
      raise "restic backup failed for #{agent.name}: #{stderr_tail.presence || 'unknown error'}" if force && !ok

      snapshot
    rescue Backup::AgentRestic::ResidentBusy
      raise
    rescue StandardError => error
      if agent && !snapshot
        # A refused transcript path says which path and why, with no values
        # in it; other errors keep only their class.
        reason = error.is_a?(Backup::AgentRestic::TranscriptRefused) ? error.message : error.class.name
        AgentBackupSnapshot.create!(agent: agent, restic_snapshot_id: "unknown",
          taken_at: Time.current, ok: false, stderr_tail: "Backup failed: #{reason}")
      end
      raise
    end

    private

    def init_restic_repo!(agent)
      cmd = restic_env(agent) + [ Backup::AgentRestic::IMAGE, "init" ]
      _out, err, status = Open3.capture3(*docker_run_cmd(agent, *cmd))
      return true if status.success? || err.include?("already initialized")

      raise "restic init failed: #{err}"
    end

    def run_restic_backup(agent, graph_mounts: [])
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cmd = restic_env(agent) + [
        Backup::AgentRestic::IMAGE, "backup", "/data",
        # Skip directories marked with CACHEDIR.TAG (Cargo's target/, and
        # other tools' caches): rebuildable output that bloats every resident's
        # backups and dedups badly.
        "--exclude-caches",
        "--tag", "agent_id=#{agent.uuid}",
        "--tag", "agent_slug=#{agent.name.to_s.parameterize}",
        "--tag", "helixkit_volume_set=v1",
        "--json"
      ]
      out, err, status = Open3.capture3(*docker_run_cmd(agent, *cmd, graph_mounts: graph_mounts))
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      parsed = parse_restic_backup(out)
      [ parsed[:snapshot_id], parsed[:total_bytes_processed], duration, status.success?, err.to_s.last(4000) ]
    end

    # Thins the history to the resident's keep rules, for a resident that
    # does not keep everything (Agent#backup_keep_all, the default: a
    # resident's backups are its only versioned history, so nothing goes by
    # age). Returns an error string, or nil.
    #
    # --group-by paths: restic applies keep rules per group, and its default
    # groups include the machine name. Each backup here runs in a throwaway
    # container with a random name, so every backup was a group of its own
    # and its group kept it: until 2026-11-16 this command had never removed
    # anything (residents held up to 169 daily backups against rules that
    # allow 23). Every backup of a resident has the one path, /data.
    def prune!(agent)
      return nil if agent.backup_keep_all? || agent.backup_never_removed?

      cmd = restic_env(agent) + [
        Backup::AgentRestic::IMAGE, "forget", "--group-by", "paths",
        "--keep-daily", agent.backup_keep_daily.to_s,
        "--keep-weekly", agent.backup_keep_weekly.to_s,
        "--keep-monthly", agent.backup_keep_monthly.to_s,
        "--prune"
      ]
      _out, err, status = Open3.capture3(*docker_run_cmd(agent, *cmd))
      status.success? ? nil : err.to_s.last(2000)
    end

    # Keeps the repository within the resident's backup space and records
    # what it holds (Backup::Fit). Returns an error string, or nil.
    def fit!(agent)
      run = lambda do |*args|
        out, err, status = Open3.capture3(*docker_run_cmd(agent, *restic_env(agent), Backup::AgentRestic::IMAGE, *args))
        raise Backup::Fit::Failed, "restic #{args.first} failed: #{err.to_s.squish.last(500)}" unless status.success?

        out
      end
      Backup::Fit.new(agent, run:).call
      nil
    rescue Backup::Fit::Failed => error
      error.message
    end

    # The backup itself succeeded, so the snapshot stays ok; a failed forget/
    # prune is recorded on it and logged instead of being silently ignored.
    def record_prune_failure(snapshot, error)
      return unless error

      Rails.logger.error("restic forget/prune failed for agent #{snapshot.agent_id}: #{error}")
      snapshot.update!(stderr_tail: [ snapshot.stderr_tail.presence, "Prune failed: #{error}" ].compact.join("\n").last(4000))
    end

    def docker_run_cmd(agent, *restic_args, graph_mounts: [])
      [ "docker", "run", "--rm", *Backup::AgentRestic.backup_mounts(agent), *graph_mounts, *restic_args ]
    end

    def restic_env(agent)
      Backup::AgentRestic.docker_environment(agent)
    end

    def parse_restic_backup(output)
      result = {}
      output.to_s.each_line do |line|
        json = JSON.parse(line)
        next unless json["message_type"] == "summary"

        result[:snapshot_id] = json["snapshot_id"]
        result[:total_bytes_processed] = json["total_bytes_processed"]
      rescue JSON::ParserError
        next
      end
      result
    end

  end
end
