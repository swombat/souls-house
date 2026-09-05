class Mnemodyne::FirstCheckpointJob < ApplicationJob

  retry_on ArgumentError, Backup::GraphCheckpoint::Error, wait: 2.minutes, attempts: 8

  def perform(agent_id)
    return unless Agents::Config.backups_enabled?
    Backup::AgentResticJob.perform_now(agent_id)
  end

end
