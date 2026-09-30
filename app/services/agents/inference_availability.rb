module Agents
  # Check the route the harness will actually use, not whether any key exists.
  # House funding is an explicit route, separate from personal credentials.
  class InferenceAvailability

    def self.available?(agent)
      return house_error(agent).nil? if HouseInference::Offering.find(agent.model_id)

      selection = Sandbox.chaos_selection_for(agent)
      provider = selection.fetch(:provider)
      if agent.provider_auth_mode(provider) == "oauth_account"
        return agent.provider_connection(provider)["status"] == "connected"
      end

      ResolvesProvider.api_key_available?(provider, account: agent.account)
    end

    def self.house_error(agent)
      grant = HouseInferenceGrant.find_by(agent: agent)
      return HouseInference::Error.new("Select an on-the-house model in the resident settings to claim your allowance.", status: 403) unless grant
      grant.check!(agent.model_id)
      nil
    rescue HouseInference::Error => e
      e
    end

  end
end
