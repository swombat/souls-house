# Keeps the disk figure on a resident's card current (#1111, jZWPXJ).
#
# On the house host the figure is storage_usage, walked daily at 04:15 by
# CollectAgentStorageUsageJob; a card here only asks for a first walk, for a
# resident never measured yet, rather than wait for the morning. A VM
# resident's figure is home_storage, walked by its runner (Agents::HomeStorage)
# at most once an hour, on the background queue, one at a time house-wide.
# The lease is shared: one ask per resident per INTERVAL, whatever it is.
class AgentHomeStorageJob < ApplicationJob

  INTERVAL = 1.hour

  queue_as :background
  limits_concurrency to: 1, key: ->(*) { "agent-home-storage" }, duration: 10.minutes

  def self.request_refresh(agent, remote: Agents::RemoteRuntime.remote?(agent))
    return unless agent.hosted?

    return if !remote && agent.storage_usage.to_h["status"].present?

    claimed = Agent.where(id: agent.id)
      .where("home_storage_requested_at IS NULL OR home_storage_requested_at < ?", INTERVAL.ago)
      .update_all(home_storage_requested_at: Time.current)
    return unless claimed.positive?

    remote ? perform_later(agent.id) : AgentStorageUsageJob.perform_later(agent.id)
  end

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id)
    return unless agent&.hosted? && Agents::RemoteRuntime.remote?(agent)

    agent.update!(home_storage: Agents::HomeStorage.new(agent).call)
  end

end
