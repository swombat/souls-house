# Brings a resident's undelivered handoffs in a room up to date after a run
# of theirs changed or a wake held for them was released or dropped
# (MessageHandoff.sync!).
class MessageHandoffSyncJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: ->(chat_id, agent_id) { "message-handoff-sync-#{chat_id}-#{agent_id}" }

  def perform(chat_id, agent_id)
    chat = Chat.find_by(id: chat_id)
    agent = Agent.find_by(id: agent_id)
    return unless chat && agent

    MessageHandoff.sync!(chat: chat, agent: agent)
  end

end
