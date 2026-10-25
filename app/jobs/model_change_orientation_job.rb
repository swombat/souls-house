class ModelChangeOrientationJob < ApplicationJob

  queue_as :default

  def perform(agent_id, expected_model_id)
    agent = Agent.find_by(id: agent_id)
    return unless agent
    return unless agent.model_id == expected_model_id
    return unless agent.external? && agent.health_state == "healthy" && !agent.billing_held?

    result = ExternalAgentOrientationRequest.new(
      agent: agent,
      requested_by: "souls.house model-change orientation",
      context: :model_change
    ).call
    return if result[:status].to_i.between?(200, 299)

    Rails.logger.warn(
      "[ModelChangeOrientationJob] Agent #{agent.id} orientation failed: " \
      "#{result[:error].presence || "HTTP #{result[:status]}"}"
    )
  end

end
