module Agents
  # Check the route the harness will actually use, not whether any key exists.
  # Future model-specific house funding belongs in that shared route selection
  # (and provisioning), not in a browser-side list of supposedly free models.
  class InferenceAvailability

    def self.available?(agent)
      selection = Sandbox.chaos_selection_for(agent)
      provider = selection.fetch(:provider)
      if agent.provider_auth_mode(provider) == "oauth_account"
        return agent.provider_connection(provider)["status"] == "connected"
      end

      ResolvesProvider.api_key_available?(provider, account: agent.account)
    end

  end
end
