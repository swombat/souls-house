class HostedAgentRuntimeReconcileJob < ApplicationJob

  LEGACY_MANAGED_RUNTIME_REPOSITORIES = %w[
    helixkit-agent-runtime
    dtenner/helix-kit-agent-runtime
  ].freeze

  queue_as :default

  retry_on Agents::Sandbox::SandboxError, wait: 5.minutes, attempts: 3

  def perform(agent_id = nil)
    scope = agent_id.present? ? Agent.where(id: agent_id) : Agent.externally_hosted

    scope.find_each do |agent|
      reconcile_agent(agent, raise_on_error: agent_id.present?)
    end
  end

  private

  def reconcile_agent(agent, raise_on_error:)
    return unless agent.externally_hosted?

    normalize_managed_runtime_image!(agent)
    sandbox = Agents::Sandbox.new(agent)
    return unless sandbox.stale_container?

    if sandbox.active_turn?
      self.class.set(wait: 5.minutes).perform_later(agent.id)
      Rails.logger.info("hosted agent runtime reconcile skipped active agent #{agent.id}; retry queued")
      return
    end

    sandbox.recreate!
    Rails.logger.info("hosted agent runtime reconcile recreated sandbox for agent #{agent.id}")
  rescue StandardError => e
    agent.update!(
      sandbox_last_error: "#{e.class}: #{e.message}",
      sandbox_last_error_at: Time.current,
      health_state: "unhealthy"
    )
    Rails.logger.error("hosted agent runtime reconcile failed for agent #{agent.id}: #{e.class}: #{e.message}")
    raise if raise_on_error
  end

  def normalize_managed_runtime_image!(agent)
    default_image = Agents::Config.default_image
    return if agent.container_image == default_image
    return unless managed_runtime_image?(agent.container_image, default_image:)

    previous_image = agent.container_image
    agent.update!(container_image: default_image)
    Rails.logger.info(
      "hosted agent runtime reconcile moved agent #{agent.id} from #{previous_image} to #{default_image}"
    )
  end

  def managed_runtime_image?(image, default_image:)
    repository = image_repository(image)
    managed_repositories = LEGACY_MANAGED_RUNTIME_REPOSITORIES + [ image_repository(default_image) ]
    repository.present? && managed_repositories.compact.include?(repository)
  end

  def image_repository(image)
    image.to_s.split("@", 2).first.sub(/:[^\/]+\z/, "").presence
  end

end
