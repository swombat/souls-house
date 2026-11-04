module Agents
  # Shared, deliberately bounded presentation for account and administrator cards.
  class ResidentDirectory

    def initialize(account)
      @account = account
    end

    # A block, when given, adds fields to each card (the site admin's grid
    # adds hosting and the account's owner).
    def call
      agents = @account.agents.for_resident_directory
      activity = ResidentActivity.new(agents).call
      integrations = ResidentIntegrations.new(@account, agents)
      node_counts = Mnemodyne::Node.joins(:vault)
        .where(mnemodyne_vaults: { agent_id: agents.select(:id) })
        .group("mnemodyne_vaults.agent_id").count

      edge_counts = Mnemodyne::Edge.joins(:vault)
        .where(mnemodyne_vaults: { agent_id: agents.select(:id) })
        .group("mnemodyne_vaults.agent_id").count

      agents.map do |agent|
        AgentJournalStatsJob.request_refresh(agent)
        agent.as_json(as: :resident_card).merge(
          activity: activity.fetch(agent.id),
          integrations: integrations.for(agent),
          mnemodyne_node_count: agent.deprecated? ? nil : node_counts.fetch(agent.id, 0),
          mnemodyne_edge_count: agent.deprecated? ? nil : edge_counts.fetch(agent.id, 0),
          provider_subscription: ProviderSubscriptionPresentation.call(agent),
          failed_runs: failed_runs_card(agent)
        ).merge(block_given? ? yield(agent) : {})
      end
    end

    private

    # The card's streak is the conversation streak. A resident the house
    # refuses to dispatch for missing setup has no conversation runs (rooms
    # refuse it before a run exists), so its scheduled refusals are the only
    # evidence: shown only when every failure in that streak is needs_setup.
    def failed_runs_card(agent)
      card = RunFailureStreak.call(agent).as_card_json
      return card if card

      # Only while the resident still lacks setup now: a repaired credential
      # leaves the old refusals in history until its next scheduled run.
      return if agent.inference_setup_message.blank?

      scheduled = RunFailureStreak.call(agent, kind: :scheduled)
      scheduled.as_card_json if scheduled.needs_setup?
    end

  end
end
