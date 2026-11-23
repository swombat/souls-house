# The disk use on a resident's card (Agents::HomeStorage), measured apart
# from the journal count. A walk of a large home takes seconds to minutes of
# disk reads, so each resident is walked at most once an hour, on the
# background queue, and only one walk runs at a time across the whole house:
# a page of cards never sets off a dozen 100 GB walks at once.
class AgentHomeStorageJob < ApplicationJob

  INTERVAL = 1.hour

  queue_as :background
  limits_concurrency to: 1, key: ->(*) { "agent-home-storage" }, duration: 10.minutes

  def self.request_refresh(agent)
    return unless agent.hosted?

    claimed = Agent.where(id: agent.id)
      .where("home_storage_requested_at IS NULL OR home_storage_requested_at < ?", INTERVAL.ago)
      .update_all(home_storage_requested_at: Time.current)
    perform_later(agent.id) if claimed.positive?
  end

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id)
    return unless agent&.hosted?

    storage = Agents::HomeStorage.new(agent).call
    agent.update!(home_storage: storage)
  end

end
