class CollectAgentStorageUsageJob < ApplicationJob

  queue_as :default

  def perform
    Agent.hosted.where.not(uuid: nil).find_each do |agent|
      AgentStorageUsageJob.perform_later(agent.id)
    end
  end

end
