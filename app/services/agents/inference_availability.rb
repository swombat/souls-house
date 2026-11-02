module Agents
  # Check the route the harness will actually use, not whether any key exists.
  # House funding is an explicit route, separate from personal credentials.
  class InferenceAvailability

    MISSING_CREDENTIALS_MESSAGE = "Edit the resident and set up credentials before asking them to respond.".freeze
    # The run's error_kind when a scheduled run is refused here, before any
    # request reaches the resident's runtime.
    NEEDS_SETUP = "needs_setup".freeze

    # A scheduled run (wake, memory aggregation) has no room to refuse in, so
    # until 2 Nov 2026 it was dispatched without this check and failed inside
    # the runtime instead: Egonomist ran every slot for eight days on an
    # OpenRouter model with no OpenRouter key ("No credentials found"), and a
    # spent house allowance surfaced as a plain runtime error. The run is
    # still recorded, so the failure streak, the owner's count and the Runs
    # tab keep their evidence, but nothing is sent to the runtime and the run
    # says why. Nil when the resident can make the run.
    def self.scheduled_refusal(agent)
      message = setup_message(agent)
      return unless message

      refusal = { "status" => "error", "error_kind" => NEEDS_SETUP, "error" => message }
      # Which house allowance refused it, when that was the reason (#678).
      code = (house_error(agent)&.code if HouseInference::Offering.find(agent.model_id))
      refusal["refusal_code"] = code if code.in?(AgentRuntimeInteraction::FailureReport::ALLOWANCE_REFUSALS)
      refusal
    end

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
      entitlement = ResidentEntitlement.find_by(agent: agent)
      if entitlement&.funds_calls?
        offering = HouseInference::Offering.find(agent.model_id)
        entitlement.check_house_call!(agent.model_id, offering.fetch(:reservation_usd))
        return nil
      end

      grant = HouseInferenceGrant.find_by(agent: agent)
      return HouseInference::Error.new("Select an on-the-house model in the resident settings to claim your allowance.", status: 403) unless grant
      grant.check!(agent.model_id)
      nil
    rescue HouseInference::Error => e
      e
    end

  end
end
