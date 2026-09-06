class Mnemodyne::FirstCheckpointJob < ApplicationJob

  retry_on StandardError, wait: 15.minutes, attempts: 12 do |job, error|
    Rails.logger.error("Mnemodyne first checkpoint exhausted for agent #{job.arguments.first}: #{error.class}")
    Rails.error.report(error, handled: false, context: { subsystem: "mnemodyne_first_checkpoint" })
    raise error
  end

  def self.next_attempt_at(agent)
    started_at = agent.agent_runtime_interactions.active.maximum(:started_at)
    [ 13.minutes.from_now, started_at && started_at + AgentRuntimeInteraction::ACTIVE_WINDOW + 1.minute ].compact.max
  end

  def perform(agent_id)
    return unless Agents::Config.backups_enabled?
    agent = Agent.find_by(id: agent_id)
    vault = agent&.memory_vault
    return unless vault && agent.externally_hosted?
    return if agent.agent_backup_snapshots.where(ok: true).where.not(graph_checkpoint_digest: nil)
      .where("taken_at >= ?", vault.created_at).exists?

    if vault.suspended_at? || vault.erasure_requested_at? || agent.agent_runtime_interactions.active.exists?
      return defer_until_idle(agent)
    end
    snapshot = Backup::AgentResticJob.perform_now(agent_id)
    raise Backup::GraphCheckpoint::Error, "First checkpoint did not complete" unless snapshot&.ok?
  rescue Backup::AgentRestic::ResidentBusy
    defer_until_idle(agent)
  end

  private

  def defer_until_idle(agent)
    Rails.logger.info("Mnemodyne first checkpoint deferred until idle for agent #{agent.id}")
    self.class.set(wait_until: self.class.next_attempt_at(agent)).perform_later(agent.id)
  end

end
