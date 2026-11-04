# How many runs each resident has going right now, by kind, for the spinners
# in the resident cards (the account's residents page and the site admin's
# All residents page). The same run-state rule as the room spinners and the
# sidebar's avatar rings (AgentRuntimeInteraction.working). One count per run,
# not per persistent Chaos session.
#
#   chat:     a conversation run (the house's rooms)
#   telegram: a Telegram run
#   other:    everything else: heartbeat wakes, memory formation, orientation…
class ResidentSessions

  KINDS = %i[chat telegram other].freeze

  def self.kind_for(trigger_kind)
    case trigger_kind
    when "conversation" then :chat
    when "telegram" then :telegram
    else :other
    end
  end

  def self.empty
    KINDS.index_with { 0 }
  end

  # { agent_id => { chat:, telegram:, other: } } for the residents that have
  # anything running; residents with nothing running are absent.
  def self.counts_for(agent_ids)
    counts = {}
    AgentRuntimeInteraction.working.where(agent_id: agent_ids)
      .group(:agent_id, :trigger_kind).count.each do |(agent_id, trigger_kind), count|
        (counts[agent_id] ||= empty)[kind_for(trigger_kind)] += count
      end
    counts
  end

  # The cards' prop: keyed by the resident's public id.
  def self.by_agent(agents)
    ids = agents.map(&:id)
    public_ids = agents.to_h { |agent| [ agent.id, agent.to_param ] }
    counts_for(ids).to_h { |agent_id, kinds| [ public_ids.fetch(agent_id), kinds ] }
  end

  # Everything running on the site, split by where it runs: the house's own
  # server, or a resident's own cloud VM (AgentPlacement backend).
  def self.site_totals
    cloud_ids = AgentPlacement.where.not(backend: "local").pluck(:agent_id).to_set
    totals = { all: empty, house: empty, vm: empty }
    counts_for(Agent.select(:id)).each do |agent_id, kinds|
      place = cloud_ids.include?(agent_id) ? :vm : :house
      kinds.each do |kind, count|
        totals[:all][kind] += count
        totals[place][kind] += count
      end
    end
    totals
  end

  def self.refresh_for(agent)
    return unless agent
    account = Account.find_by(id: agent.account_id)
    ActionCable.server.broadcast("ResidentSessions:#{account.obfuscated_id}", { action: "refresh" }) if account
    ActionCable.server.broadcast("ResidentSessions:all", { action: "refresh" })
  rescue StandardError => error
    Rails.logger.warn("Resident sessions refresh failed: #{error.class}")
  end

end
