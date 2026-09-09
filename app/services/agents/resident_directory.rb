module Agents
  # Shared, deliberately bounded presentation for account and administrator cards.
  class ResidentDirectory
    def initialize(account)
      @account = account
    end

    def call
      agents = @account.agents.for_resident_directory
      activity = ResidentActivity.new(agents).call
      integrations = ResidentIntegrations.new(@account, agents)
      node_counts = Mnemodyne::Node.joins(:vault)
        .where(mnemodyne_vaults: { agent_id: agents.select(:id) })
        .group("mnemodyne_vaults.agent_id").count

      agents.map do |agent|
        AgentJournalStatsJob.request_refresh(agent)
        agent.as_json(as: :resident_card).merge(
          activity: activity.fetch(agent.id),
          integrations: integrations.for(agent),
          mnemodyne_node_count: agent.deprecated? ? nil : node_counts.fetch(agent.id, 0),
          provider_subscription: ProviderSubscriptionPresentation.call(agent)
        )
      end
    end
  end
end
