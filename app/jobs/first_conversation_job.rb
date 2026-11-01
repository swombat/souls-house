# Opens a new resident's first conversation (Agents::FirstConversation).
class FirstConversationJob < ApplicationJob

  queue_as :default

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id) or return
    Agents::FirstConversation.open!(agent)
  end

end
