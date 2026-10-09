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

    AgentPlacement.where.not(cleanup_requested_at: nil).where.not(state: "retired")
      .pluck(:id).each { |placement_id| VmCleanupJob.perform_later(placement_id) }

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
