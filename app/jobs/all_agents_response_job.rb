class AllAgentsResponseJob < ApplicationJob

  def perform(chat, agent_ids)
    return if agent_ids.empty? || !chat.respondable? || !chat.manual_responses?

    agent = chat.agents.find_by(id: agent_ids.first)
    ManualAgentResponseJob.perform_now(chat, agent) if agent
    remaining = agent_ids.drop(1)
    self.class.perform_later(chat, remaining) if remaining.any?
  end

end
