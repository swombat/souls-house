module Backup
  # Runs after a VM resident's backup is verified (VmResident.settle!). A
  # failure is recorded on the resident's newest good snapshot and logged, as
  # a house resident's failed prune is; the backup itself stays good.
  class VmThinningJob < ApplicationJob

    queue_as :default

    def perform(agent_id, thinning: VmThinning.new)
      return unless Agents::Config.backups_enabled?

      agent = Agent.find_by(id: agent_id)
      return unless agent && Agents::RemoteRuntime.remote?(agent)
      return if agent.account.disabled?
      # A backup is in flight: it will ask for thinning again when it settles.
      return if VmResident.held?(agent)

      result = thinning.call(agent)
      Rails.logger.info("[vm_backup] thinned agent_id=#{agent.id} kept=#{result.kept} removed=#{result.removed}")
      result
    rescue VmThinning::Failed => error
      Rails.logger.error("[vm_backup] thinning failed agent_id=#{agent.id}: #{error.message}")
      snapshot = agent.agent_backup_snapshots.where(ok: true).order(taken_at: :desc).first
      snapshot&.update!(stderr_tail: [ snapshot.stderr_tail.presence, "Prune failed: #{error.message}" ].compact.join("\n").last(4000))
      nil
    end

  end
end
