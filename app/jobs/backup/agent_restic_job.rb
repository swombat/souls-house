module Backup
  class AgentResticJob < ApplicationJob

    queue_as :default

    def perform(agent_id, force: false)
      return unless force || Agents::Config.backups_enabled?

      agent = Agent.find(agent_id)
      return unless agent.externally_hosted?

      init_restic_repo!(agent)
      backup_started_at = Time.current
      checkpoint = nil
      snapshot_id, size, duration_ms, ok, stderr_tail = Backup::GraphCheckpoint.with_volume(agent) do |mounts, envelope|
        checkpoint = envelope
        run_restic_backup(agent, graph_mounts: mounts)
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
      prune!(agent) if ok
      raise "restic backup failed for #{agent.name}: #{stderr_tail.presence || 'unknown error'}" if force && !ok

      snapshot
    end

    private

    def init_restic_repo!(agent)
      cmd = restic_env(agent) + [ "restic/restic:latest", "init" ]
      _out, err, status = Open3.capture3(*docker_run_cmd(agent, *cmd))
      return true if status.success? || err.include?("already initialized")

      raise "restic init failed: #{err}"
    end

    def run_restic_backup(agent, graph_mounts: [])
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cmd = restic_env(agent) + [
        "restic/restic:latest", "backup", "/data",
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

    def prune!(agent)
      cmd = restic_env(agent) + [
        "restic/restic:latest", "forget",
        "--keep-daily", agent.backup_keep_daily.to_s,
        "--keep-weekly", agent.backup_keep_weekly.to_s,
        "--keep-monthly", agent.backup_keep_monthly.to_s,
        "--prune"
      ]
      Open3.capture3(*docker_run_cmd(agent, *cmd))
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
