module Backup
  # Scheduled (config/recurring.yml). Looks at every resident that carries a
  # thinning mark and does the two things the mark depends on:
  #
  # - a mark nobody is renewing (the job that held it died, for example when
  #   a deploy stopped the worker) is sent back to VmThinningJob, which
  #   recovers the repository and thins again;
  # - backups that have stayed paused past VmThinning::ALERT_AFTER are
  #   reported to the people who run the house, naming the resident.
  #
  # No backup is issued while a mark stands (VmResident.issue!), so without
  # this job an interrupted thinning pauses a resident's backups for good.
  # That happened to one resident on 15 Nov 2026: this recovery lived only in
  # AgentBackupSweeperJob, which has never been on the schedule.
  class VmThinningRecoveryJob < ApplicationJob

    queue_as :default

    def perform
      return unless Agents::Config.backups_enabled?

      Agent.where.not(backup_thinning_started_at: nil)
        .where(account_id: Account.enabled.select(:id)).find_each do |agent|
        next if VmResident.held?(agent)

        VmThinningJob.perform_later(agent.id) if VmThinning.abandoned?(agent)
        report_stalled(agent)
      end
    end

    private

    def report_stalled(agent)
      since = agent.backup_thinning_interrupted_at
      return unless since && since <= VmThinning::ALERT_AFTER.ago

      Rails.error.report(VmThinning::Stalled.new(
        "Backups for resident #{agent.id} (#{agent.name}) have been paused since #{since.utc.iso8601}: " \
        "an interrupted backup clean-up could not be confirmed stopped"), handled: true)
    end

  end
end
