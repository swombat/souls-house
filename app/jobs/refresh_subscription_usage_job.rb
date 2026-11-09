# Reads a resident's provider subscription usage again in the background, so
# the card that found a stale figure did not have to wait for it (see
# Agents::SubscriptionUsageSnapshot).
class RefreshSubscriptionUsageJob < ApplicationJob

  queue_as :default

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id)
    return unless agent # its refresh lock simply expires

    Agents::SubscriptionUsageSnapshot.new(agent).refresh!
  end

end
