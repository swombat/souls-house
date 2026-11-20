class AgentJournalStatsJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: ->(agent_id) { agent_id }, duration: 2.minutes

  # A short lease prevents refreshes (including Action Cable reloads) from
  # endlessly enqueueing measurements. An abandoned job can be retried later.
  def self.request_refresh(agent)
    return unless agent.hosted?

    claimed = Agent.where(id: agent.id)
      .where("journal_stats_requested_at IS NULL OR journal_stats_requested_at < ?", 2.minutes.ago)
      .update_all(journal_stats_requested_at: Time.current)
    perform_later(agent.id) if claimed.positive?
  end

  def perform(agent_id)
    agent = Agent.find_by(id: agent_id)
    return unless agent&.hosted?

    measured_from = agent.journal_source
    stats = Agents::JournalEntryStats.new(agent).call
    # A measurement taken while the chosen journal changed belongs to the
    # old one: drop it rather than put that count on the new journal's card.
    agent.with_lock do
      agent.update!(journal_entry_stats: stats) if agent.journal_source == measured_from
    end
  end

end
