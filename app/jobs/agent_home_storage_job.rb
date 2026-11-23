# The disk figure on a VM resident's card (#1111, jZWPXJ): home_storage,
# walked by its runner (Agents::HomeStorage) at most once an hour, on the
# background queue, one at a time house-wide. A resident on the house host
# needs nothing from here: its figure is storage_usage, walked daily at 04:15
# by CollectAgentStorageUsageJob, and a card view never starts a walk on the
# house host (a page of new residents would fill the shared worker; Mira).
class AgentHomeStorageJob < ApplicationJob

  INTERVAL = 1.hour

  queue_as :background
  limits_concurrency to: 1, key: ->(*) { "agent-home-storage" }, duration: 10.minutes

  def self.request_refresh(agent, remote: Agents::RemoteRuntime.remote?(agent))
    return unless remote && agent.hosted?

    claimed = Agent.where(id: agent.id)
      .where("home_storage_requested_at IS NULL OR home_storage_requested_at < ?", INTERVAL.ago)
      .update_all(home_storage_requested_at: Time.current)
    perform_later(agent.id) if claimed.positive?
  end

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id)
    return unless agent&.hosted? && Agents::RemoteRuntime.remote?(agent)

    agent.update!(home_storage: Agents::HomeStorage.new(agent).call)
  end

end
