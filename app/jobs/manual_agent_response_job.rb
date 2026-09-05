class ManualAgentResponseJob < ApplicationJob

  def perform(chat, agent, initiation_reason: nil)
    return unless chat.respondable? && chat.manual_responses? && chat.agents.exists?(agent.id)
    agent.reload
    agent.require_conversation_runtime!

    ExternalAgentResponseRequest.new(
      agent: agent, chat: chat, requested_by: "souls.house",
      initiation_reason: initiation_reason
    ).call
  rescue Agent::RuntimeAvailability::Unavailable => error
    ActionCable.server.broadcast("Chat:#{chat.to_param}", {
      action: "agent_skipped", agent_id: agent.to_param,
      message: "#{agent.name} is unavailable", reason: error.code
    })
  end

end
