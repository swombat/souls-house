# Wakes a new resident once in its first conversation (Agents::FirstConversation).
class FirstConversationWakeJob < ApplicationJob

  queue_as :default

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id) or return
    Agents::FirstConversation.wake!(agent)
  end

end
