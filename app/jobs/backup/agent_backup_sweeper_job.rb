module Backup
  class AgentBackupSweeperJob < ApplicationJob

    queue_as :default

    def perform
      return unless Agents::Config.backups_enabled?

      Agent.where(runtime: "external").find_each do |agent|
        next if VmResident.held?(agent)
        next unless due?(agent)
        Backup::AgentResticJob.perform_later(agent.id)
      end
    end

    private

    def due?(agent)
      last = agent.agent_backup_snapshots.where(ok: true).order(taken_at: :desc).first
      last.nil? || last.taken_at <= agent.backup_interval_hours.hours.ago
    end

  end
end
