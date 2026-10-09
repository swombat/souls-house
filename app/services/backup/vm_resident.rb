module Backup
  # One durable hold couples a house graph checkpoint with the VM filesystem.
  # Losing a command reply does not release the hold: an unknown pause state
  # needs containment, not a timer declaring the resident safe to run.
  class VmResident

    class Unavailable < ArgumentError; end
    DEADLINE = 10.minutes

    def self.held?(agent)
      VmBackup.holding.where(agent_id: agent.id).exists?
    end

    def self.issue!(placement:)
      raise Unavailable, "Backup requires a VM placement" unless placement.backend == "hetzner_cloud"
      agent = placement.agent
      Agent.transaction do
        # Same gate as asynchronous turn admission; lock order is gate, agent,
        # vault, enrollment. Interaction reservations also take the agent lock.
        Agent.connection.execute("SELECT pg_advisory_xact_lock(1936680308, 1)")
        agent.with_lock do
          raise Unavailable, "Backup already pending" if held?(agent)
          raise AgentRestic::ResidentBusy, "Backup requires an idle resident" if busy?(agent)
          enrollment = Agents::RemoteRuntime.live_enrollment!(agent)
          raise Unavailable, "Backup requires a healthy runner" unless enrollment.healthy?
          raise Unavailable, "Backup password is missing" if agent.restic_password.blank?
          vault = agent.memory_vault
          if vault
            vault.with_lock do
              raise Unavailable, "Memory erasure is pending" if vault.erasure_requested_at?
              enqueue!(agent, enrollment, Mnemodyne::Checkpoint.export(vault))
            end
          else
            enqueue!(agent, enrollment, nil)
          end
        end
      end
    end

    def self.status(command:, verifier: VmSnapshotVerifier.new)
      backup = VmBackup.find_by!(runner_command_id: command.id)
      return answer(backup) unless backup.state == "pending"
      command.reload
      if !command.terminal?
        return { state: "pending", reason: nil, snapshot: nil } if Time.current < backup.deadline_at
        # Do not infer unpause from deadline or silence. Hold survives until
        # the runner reports a known state or an operator contains the VM.
        return settle!(backup, {}, "Backup deadline expired; runtime state uncertain, hold retained", release: false)
      end
      result = command.result["result"].is_a?(Hash) ? command.result["result"] : {}
      safe = result["unpaused"] == true
      reason = if command.state != "done"
        "Runner backup #{command.state}"
      elsif !safe
        "Runner did not confirm an unpaused runtime"
      elsif command.generation != command.agent_placement.reload.generation
        "Placement generation changed"
      elsif busy?(backup.agent) || overlapped?(backup)
        "Resident activity overlapped graph/identity backup"
      elsif result["checkpoint_digest"] != backup.checkpoint_digest ||
          result["checkpoint_file_sha256"] != backup.checkpoint_file_digest
        "Runner checkpoint does not match the issued envelope"
      end
      if reason.nil?
        verifier.verify!(agent: backup.agent, snapshot_id: result["snapshot_id"],
          checkpoint_digest: backup.checkpoint_digest, checkpoint_file_digest: backup.checkpoint_file_digest)
      end
      settle!(backup, result, reason, release: safe)
    rescue VmSnapshotVerifier::Invalid => error
      settle!(backup, result, error.message, release: safe)
    end

    def self.busy?(agent)
      agent.agent_runtime_interactions.active.exists? ||
        ResidentTurn.occupying_capacity.where(agent_id: agent.id).exists? ||
        RunnerCommand.joins(:agent_placement).where(agent_placements: { agent_id: agent.id },
          kind: %w[submit_turn start_resident stop_resident seed_home], state: %w[queued delivered unknown]).exists?
    end

    # Cleanup may release a held checkpoint only after the placement has
    # actually been retired and its runner revoked. A timer is not containment.
    def self.release_after_retirement!(placement:)
      placement.reload
      raise Unavailable, "Placement must be retired" unless placement.backend == "hetzner_cloud" && placement.state == "retired"
      raise Unavailable, "Runner must be revoked" if RunnerEnrollment.where(agent_placement: placement, revoked_at: nil).exists?
      placement.agent.with_lock do
        VmBackup.holding.where(agent_id: placement.agent_id).each do |backup|
          backup.update!(state: "failed", failure_reason: "VM retired after backup containment",
            released_at: Time.current)
        end
      end
    end

    def self.enqueue!(agent, enrollment, envelope)
      # Preserve the exact bytes, not a Python re-serialization of Ruby JSON.
      checkpoint_json = JSON.generate(envelope)
      file_digest = Digest::SHA256.hexdigest(checkpoint_json)
      command = RunnerCommand.enqueue!(enrollment:, kind: "backup_resident", payload: {
        "container_name" => agent.container_name, "agent_uuid" => agent.uuid,
        "agent_slug" => agent.name.to_s.parameterize.presence || agent.uuid,
        "restic_password" => agent.restic_password,
        "checkpoint_json" => checkpoint_json,
        "checkpoint_digest" => envelope&.fetch("sha256"),
        "checkpoint_file_sha256" => file_digest,
        "deadline_seconds" => DEADLINE.to_i
      })
      VmBackup.create!(agent:, runner_command: command, checkpoint_digest: envelope&.fetch("sha256"),
        checkpoint_file_digest: file_digest, deadline_at: DEADLINE.from_now)
      VmBackupCheckJob.set(wait: 10.seconds).perform_later(command.id)
      command
    end
    private_class_method :enqueue!

    def self.overlapped?(backup)
      backup.agent.agent_runtime_interactions.where("started_at >= ?", backup.created_at).exists?
    end
    private_class_method :overlapped?

    def self.settle!(backup, result, reason, release:)
      backup.agent.with_lock do
        backup.with_lock do
          return answer(backup) unless backup.state == "pending"
          reason ||= "Resident activity overlapped graph/identity backup" if busy?(backup.agent) || overlapped?(backup)
          snapshot = AgentBackupSnapshot.create!(agent: backup.agent,
            restic_snapshot_id: result["snapshot_id"].presence || "unknown",
            graph_checkpoint_digest: backup.checkpoint_digest,
            graph_schema_version: backup.checkpoint_digest && Mnemodyne::Checkpoint::VERSION,
            taken_at: Time.current, size_bytes: result["size_bytes"],
            duration_ms: result["duration_ms"], ok: reason.nil?, stderr_tail: reason)
          backup.update!(state: reason.nil? ? "verified" : "failed", failure_reason: reason,
            agent_backup_snapshot: snapshot, released_at: release ? Time.current : nil)
          answer(backup)
        end
      end
    end
    private_class_method :settle!

    def self.answer(backup)
      { state: backup.state, reason: backup.failure_reason, snapshot: backup.agent_backup_snapshot }
    end
    private_class_method :answer

  end
end
