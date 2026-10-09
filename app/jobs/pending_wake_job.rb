# Runs shortly after a resident's conversation run ends (see
# AgentRuntimeInteraction#enqueue_pending_wake_release) and releases any wake
# that was queued for that resident in that room while the run was busy.
# Cheap when there is none, which is almost always. It deliberately does not
# check for an open wake before taking the chat lock: a queue! that saw the
# run as busy may not have committed yet, and the lock is what waits for it.
class PendingWakeJob < ApplicationJob

  DELAY = 2.seconds

  queue_as :default
  limits_concurrency to: 1, key: ->(chat_id, agent_id) { "pending-wake-#{chat_id}-#{agent_id}" }

  def perform(chat_id, agent_id)
    chat = Chat.find_by(id: chat_id)
    agent = Agent.find_by(id: agent_id)
    return unless chat && agent

    PendingWake.release!(chat: chat, agent: agent)
  end

end
