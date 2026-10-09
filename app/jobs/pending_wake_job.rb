# Releases the held wake for a resident in a room, if one is due.
#
# The rule (Mira's third review of #252): a release is attempted after every
# commit that can make a wake due. There are two:
#
# - the busy run ending (AgentRuntimeInteraction#enqueue_pending_wake_release,
#   on the commit that sets finished_at);
# - the wake itself being written (PendingWake.queue!, after the commit that
#   created or coalesced it).
#
# Whichever commits second finds the other already committed. If the run
# ends first, the wake's own job sees it free and releases it. If the wake
# commits first, the run-end job sees it. A release that finds the resident
# still busy does nothing, and the later run end tries again. Neither job
# relies on seeing an uncommitted row, so neither needs to wait for one.
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
