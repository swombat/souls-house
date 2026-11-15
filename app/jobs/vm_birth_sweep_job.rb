# Keeps VM births and cleanups moving if a scheduled follow-up was lost
# (#246 slice 5). Both jobs read current state and are safe to run twice, so
# the sweep only re-enqueues; it decides nothing.
class VmBirthSweepJob < ApplicationJob

  queue_as :default

  def perform
    births = AgentPlacement.where(backend: "hetzner_cloud", state: %w[pending ready], cleanup_requested_at: nil)
      .where.not(admitted_by_setting_at: nil)
      .joins(:agent).where(agents: { runtime_ready_at: nil })
    births.pluck(:agent_id).each { |agent_id| ProvisionVmAgentJob.perform_later(agent_id) }

    # A ready GitHub import approved again, waiting on its trust check or a
    # refresh refused as busy.
    AgentPlacement.where(backend: "hetzner_cloud", kind: "github_import", state: "ready")
      .joins(agent: :github_resident_import).where(github_resident_imports: { status: "provisioning" })
      .where.not(agents: { runtime_ready_at: nil })
      .pluck(:agent_id).each { |agent_id| ProvisionVmAgentJob.perform_later(agent_id) }

    AgentPlacement.where.not(cleanup_requested_at: nil).where.not(state: "retired")
      .pluck(:id).each { |placement_id| VmCleanupJob.perform_later(placement_id) }

    # A rollback's server whose release was asked for and isn't confirmed
    # (#426). Placement cleanup can't carry it: the placement is local.
    VmRollback.releasing.pluck(:id).each { |rollback_id| VmRollbackReleaseJob.perform_later(rollback_id) }

    # A move between servers left open with no job (Agents::ServerMove).
    # The same for a release that was claimed and not finished.
    VmServerMove.where(phase: VmServerMove::OPEN_PHASES + [ "releasing" ]).where(updated_at: ..1.minute.ago)
      .pluck(:id).each { |move_id| VmServerMoveJob.perform_later(move_id) }

    # A move that settled after its account was disabled: a disabled account
    # keeps no servers (Account#release_vm_servers).
    VmServerMove.where(phase: VmServerMove::SETTLED_PHASES)
      .where(agent_id: Agent.where(account_id: Account.where.not(disabled_at: nil).select(:id)).select(:id))
      .find_each { |move| Agents::ServerMove.new.release_for_disabled_account!(move) }

    # A credential/service restart whose settle job was lost.
    AgentPlacement.where.not(refresh_command_id: nil).where("refresh_requested_at < ?", 1.minute.ago)
      .pluck(:id).each { |placement_id| RemoteRefreshSettleJob.perform_later(placement_id) }

    # Retired, but a backup hold was never released (a transient failure in
    # the release after retirement). Only these come back; every other
    # retired placement is finished and stays out of the sweep.
    AgentPlacement.where(state: "retired").where.not(cleanup_requested_at: nil)
      .where(agent_id: VmBackup.holding.select(:agent_id))
      .pluck(:id).each { |placement_id| VmCleanupJob.perform_later(placement_id) }
  end

end
