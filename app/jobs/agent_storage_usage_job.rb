class AgentStorageUsageJob < ApplicationJob

  queue_as :default
  # The lock outlasts the longest walk (#1200): with a fixed 10 minutes, a
  # walk that used its whole budget could overlap a second one of the same home.
  limits_concurrency to: 1, key: ->(agent_id) { agent_id },
    duration: (Agents::StorageUsage::MAX_CALL_SECONDS + 300).seconds

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id)
    return unless agent

    agent.update!(storage_usage: Agents::StorageUsage.new(agent).call)
  end

end
