class AllAgentsResponseJob < ApplicationJob

  def perform(chat, agent_ids)
    return if agent_ids.empty? || !chat.respondable? || !chat.manual_responses?

    agent = chat.agents.find_by(id: agent_ids.first)
    result = ManualAgentResponseJob.perform_now(chat, agent) if agent
    if result.is_a?(Hash) && (result[:status] == 0 || result[:status] == 409 || result[:execution_unconfirmed])
      ActionCable.server.broadcast("Chat:#{chat.to_param}", {
        action: "error",
        message: "Agent chain stopped: execution could not be confirmed. Remaining residents were not started."
      })
      return
    end
    remaining = agent_ids.drop(1)
    self.class.perform_later(chat, remaining) if remaining.any?
  end

end
