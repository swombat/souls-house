module Agents
  class ProviderSubscriptionPresentation

    PROVIDER_NAMES = {
      "anthropic" => "Claude",
      "gemini" => "Google AI",
      "openai" => "ChatGPT",
      "xai" => "xAI"
    }.freeze

    def self.call(agent)
      new(agent).call
    end

    def initialize(agent)
      @agent = agent
    end

    def call
      return unless @agent.externally_hosted?

      provider = Agents::Sandbox.subscription_provider_for(@agent)
      return unless provider

      {
        id: @agent.to_param,
        name: @agent.name,
        provider: provider,
        provider_name: PROVIDER_NAMES.fetch(provider),
        runtime: @agent.runtime,
        available: @agent.external? && @agent.health_state == "healthy",
        auth_mode: @agent.provider_auth_mode(provider),
        connection: @agent.provider_connection(provider)
      }
    rescue KeyError
      nil
    end

  end
end
