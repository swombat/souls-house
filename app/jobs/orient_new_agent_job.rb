class OrientNewAgentJob < ApplicationJob

  queue_as :default

  def perform(agent_id)
    agent = Agent.find(agent_id)
    return unless agent.born_hosted? && agent.external? && agent.health_state == "healthy"

    agent.update!(
      orientation_requested_at: Time.current,
      orientation_completed_at: nil,
      orientation_last_error: nil,
      orientation_last_error_at: nil
    )
    result = ExternalAgentOrientationRequest.new(
      agent: agent,
      requested_by: "HelixKit first-wake orientation",
      context: :birth
    ).call

    return if result[:status] == 202
    if result[:status].to_i.between?(200, 299)
      agent.update!(orientation_completed_at: Time.current)
    else
      agent.update!(
        orientation_last_error: result[:error].presence || "Runtime returned HTTP #{result[:status]}",
        orientation_last_error_at: Time.current
      )
    end
  rescue StandardError => e
    agent&.update!(
      orientation_last_error: "#{e.class}: #{e.message}",
      orientation_last_error_at: Time.current
    )
    raise
  end

end
