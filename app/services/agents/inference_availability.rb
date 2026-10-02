module Agents
  # Check the route the harness will actually use, not whether any key exists.
  # House funding is an explicit route, separate from personal credentials.
  class InferenceAvailability

    MISSING_CREDENTIALS_MESSAGE = "Edit the resident and set up credentials before asking them to respond.".freeze

    def self.setup_message(agent)
      if HouseInference::Offering.find(agent.model_id)
        error = house_error(agent)
        # A pending call is temporary admission pressure, not missing setup.
        # Another conversation may queue behind it; orientation itself can be
        # the pending call, so do not mislabel its first wake as broken.
        return error&.message unless error&.code == "house_inference_busy"
        return nil
      end

      MISSING_CREDENTIALS_MESSAGE unless available?(agent)
    end

    def self.dispatchable?(agent)
      setup_message(agent).nil?
    end

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
