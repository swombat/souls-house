module Backup
  # Runs after a VM resident's backup is verified (VmResident.settle!), and
  # from the sweeper when a thinning was left interrupted.
  #
  # It marks the resident for as long as it runs. VmResident.issue! refuses a
  # backup while the mark is fresh, and this job does not start while a backup
  # is held; both decide under the agent lock, so the two never overlap.
  #
  # A failure is recorded on the resident's newest good snapshot and logged,
  # as a house resident's failed prune is; the backup itself stays good. After
  # any failure, and when taking over a mark a dead job left, the repository
  # is recovered (VmThinning#recover) before the mark is cleared, so a lock
  # left by a killed prune never waits on a later backup to be removed.
  class VmThinningJob < ApplicationJob

    queue_as :default

    def perform(agent_id, thinning: VmThinning.new)
      return unless Agents::Config.backups_enabled?

      agent = Agent.find_by(id: agent_id)
      return unless agent && Agents::RemoteRuntime.remote?(agent)
      return if agent.account.disabled?

      claim = claim!(agent) or return
      failed = claim[:took_over]
      begin
        thinning.recover(agent) if claim[:took_over]
        failed = false
        result = thinning.call(agent)
        Rails.logger.info("[vm_backup] thinned agent_id=#{agent.id} kept=#{result.kept} removed=#{result.removed}")
        result
      rescue VmThinning::Failed => error
        failed = true
        record_failure(agent, error)
        nil
      ensure
        release!(agent, claim[:started_at], recover_with: failed ? thinning : nil)
      end
    end

    private

    # Under the agent lock: nil when a backup is held or another thinning is
    # running; otherwise the mark, and whether it replaced an abandoned one.
    def claim!(agent)
      agent.with_lock do
        next nil if VmResident.held?(agent) || VmThinning.running?(agent)

        took_over = VmThinning.abandoned?(agent)
        started_at = Time.current.change(usec: 0)
        agent.update_columns(backup_thinning_started_at: started_at)
        { started_at:, took_over: }
      end
    end

    # Recovery runs while the mark is still ours. If recovery itself fails the
    # mark stays, so no backup is issued into a repository that may be locked,
    # and the sweeper comes back for it once the mark is old enough.
    def release!(agent, started_at, recover_with:)
      recover_with&.recover(agent)
      Agent.where(id: agent.id, backup_thinning_started_at: started_at).update_all(backup_thinning_started_at: nil)
    rescue VmThinning::Failed => error
      record_failure(agent, error)
    end

    def record_failure(agent, error)
      Rails.logger.error("[vm_backup] thinning failed agent_id=#{agent.id}: #{error.message}")
      snapshot = agent.agent_backup_snapshots.where(ok: true).order(taken_at: :desc).first
      snapshot&.update!(stderr_tail: [ snapshot.stderr_tail.presence, "Prune failed: #{error.message}" ].compact.join("\n").last(4000))
    end

  end
end
