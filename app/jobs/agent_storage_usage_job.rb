class AgentStorageUsageJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: ->(agent_id) { agent_id }, duration: 10.minutes

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id)
    return unless agent

    agent.update!(storage_usage: Agents::StorageUsage.new(agent).call)
  end

end
