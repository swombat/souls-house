module Backup
  class AgentBackupSweeperJob < ApplicationJob

    queue_as :default

    def perform
      return unless Agents::Config.backups_enabled?

      # A disabled account's servers are being deleted; nothing to back up.
      Agent.where(runtime: "external", account_id: Account.enabled.select(:id)).find_each do |agent|
        next if VmResident.held?(agent)
        # A thinning that died left its mark, and maybe a repository lock:
        # recover it. No backup is issued while any mark stands.
        Backup::VmThinningJob.perform_later(agent.id) if VmThinning.abandoned?(agent)
        report_stalled(agent)
        next if agent.backup_thinning_started_at.present?
        next unless due?(agent)
        Backup::AgentResticJob.perform_later(agent.id)
      end
    end

    private

    # Backups paused too long behind a recovery that keeps failing: tell the
    # people who run the house, naming the resident.
    def report_stalled(agent)
      since = agent.backup_thinning_interrupted_at
      return unless agent.backup_thinning_started_at.present? && since && since <= VmThinning::ALERT_AFTER.ago

      Rails.error.report(VmThinning::Stalled.new(
        "Backups for resident #{agent.id} (#{agent.name}) have been paused since #{since.utc.iso8601}: " \
        "an interrupted backup clean-up could not be confirmed stopped"), handled: true)
    end

    def due?(agent)
      last = agent.agent_backup_snapshots.where(ok: true).order(taken_at: :desc).first
      last.nil? || last.taken_at <= agent.backup_interval_hours.hours.ago
    end

  end
end
