class ProvisionAgentJob < ApplicationJob

  queue_as :default

  def perform(agent_id)
    agent = Agent.find(agent_id)
    return unless agent.provisioning?
    admitted = true

    volume = Agents::Volume.new(agent)
    volume.ensure!
    volume.seed_from_exporter! if volume.empty?
    agent.update!(identity_seeded_at: Time.current) if agent.born_hosted? && agent.identity_seeded_at.blank?
    init_restic_repo!(agent) if Agents::Config.backups_enabled?
    Agents::Sandbox.new(agent).spawn!
    if agent.born_hosted?
      agent.update!(runtime_ready_at: Time.current)
      OrientNewAgentJob.perform_later(agent.id)
    end
    Backup::AgentResticJob.perform_later(agent.id) if Agents::Config.backups_enabled?
  rescue StandardError => e
    if admitted && agent&.reload&.hosted?
      agent.update!(
        runtime: agent.born_hosted? ? "provisioning" : agent.runtime,
        health_state: "unhealthy",
        sandbox_last_error: "#{e.class}: #{e.message}",
        sandbox_last_error_at: Time.current
      )
    end
    Rails.logger.error("provisioning failed for agent #{agent_id}: #{e.class}")
    raise
  end

  private

  def init_restic_repo!(agent)
    Backup::AgentResticJob.new.send(:init_restic_repo!, agent)
  end

end
