# Daily, before HouseStorageSampleJob keeps its history (04:40). Residents are
# spaced out so the house never walks every home's volumes at once.
class CollectAgentStorageUsageJob < ApplicationJob

  queue_as :default

  SPACING = 20.seconds

  def perform
    Agent.hosted.where.not(uuid: nil).order(:id).each_with_index do |agent, index|
      AgentStorageUsageJob.set(wait: index * SPACING).perform_later(agent.id)
    end
  end

end
