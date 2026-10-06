module Agents
  # Which models a resident could run sub-agents on, given the credentials its
  # runtime actually receives: provider subscriptions connected for this
  # resident, and the account's API keys (Sandbox#provider_env_args passes every
  # account key into the container, except for house-funded residents).
  class SubagentCatalog

    PROVIDER_LABELS = {
      "anthropic" => "Anthropic",
      "openai" => "OpenAI",
      "gemini" => "Google AI",
      "xai" => "xAI",
      "openrouter" => "OpenRouter"
    }.freeze

    DIRECT_MODEL_PREFIXES = {
      "anthropic" => "anthropic/",
      "openai" => "openai/",
      "gemini" => "google/",
      "xai" => "x-ai/"
    }.freeze

    # On a Claude subscription Chaos runs Claude Code (clamp), and spawn_agent
    # accepts only the names Claude Code advertises at start-up, not API model
    # IDs. Offered only to residents whose own runtime is that subscription. These are the ones it advertised on 2026-10-06; others can be added
    # by ID.
    CLAUDE_CODE_MODELS = [
      [ "haiku", "Claude Haiku (latest)" ],
      [ "sonnet", "Claude Sonnet (latest)" ],
      [ "opus[1m]", "Claude Opus (latest, 1M context)" ],
      [ "claude-fable-5-1[1m]", "Claude Fable 5.1 (1M context)" ]
    ].freeze

    attr_reader :agent

    def initialize(agent)
      @agent = agent
    end

    # [{ provider:, provider_label:, source: }]
    def providers
      @providers ||= begin
        direct = DIRECT_MODEL_PREFIXES.keys.filter_map do |provider|
          source = source_for(provider)
          provider_entry(provider, source) if source
        end
        direct << provider_entry("openrouter", "API key") if api_key?(:openrouter)
        direct
      end
    end

    # [{ key:, provider:, provider_label:, source:, model:, label: }]
    def options
      @options ||= providers.flat_map { |entry| options_for(entry) }.uniq { |option| option[:key] }
    end

    # The catalogue entry for a key, or a custom entry when the provider is
    # available but the model is not one the house lists. Nil when the
    # provider's credentials are gone.
    def resolve(key)
      option = options.find { |candidate| candidate[:key] == key }
      return option if option

      provider, model = key.to_s.split(":", 2)
      entry = providers.find { |candidate| candidate[:provider] == provider }
      return unless entry && model.present?

      entry.merge(key: key, model: model, label: model, custom: true)
    end

    def empty_reason
      return if providers.any?

      if house_funded?
        "This resident runs on house-funded inference, which does not pass account keys to its runtime. Switch it to an account key or a subscription to choose sub-agent models."
      else
        "Add an API key in account settings, or connect a subscription on the Hosting tab, to choose sub-agent models."
      end
    end

    private

    def options_for(entry)
      provider = entry[:provider]
      if provider == "anthropic" && subscription?(provider)
        return CLAUDE_CODE_MODELS.map { |model, label| entry.merge(key: "#{provider}:#{model}", model: model, label: label) }
      end

      catalogue_models.filter_map do |config|
        model = if provider == "openrouter"
          config[:model_id]
        elsif config[:model_id].start_with?(DIRECT_MODEL_PREFIXES.fetch(provider))
          config[:provider_model_id]
        end
        entry.merge(key: "#{provider}:#{model}", model: model, label: config[:label]) if model.present?
      end
    end

    def catalogue_models
      @catalogue_models ||= Chat::MODELS.reject { |config| config[:group] == "Top Models" }
        .uniq { |config| config[:model_id] }
    end

    def provider_entry(provider, source)
      { provider: provider, provider_label: PROVIDER_LABELS.fetch(provider), source: source }
    end

    def source_for(provider)
      return "#{ProviderSubscriptionPresentation::PROVIDER_NAMES.fetch(provider)} subscription" if subscription?(provider)

      "API key" if api_key?(provider)
    end

    # A subscription is reachable only as the resident's own provider: at the
    # pinned Chaos, a child on a different provider uses that provider's direct
    # API transport, so another provider's subscription cannot be reached by
    # passing `model_provider`.
    def subscription?(provider)
      Agent::OAUTH_ACCOUNT_PROVIDERS.include?(provider) &&
        agent.provider_auth_mode(provider) == "oauth_account" &&
        provider == own_provider
    end

    def own_provider
      return @own_provider if defined?(@own_provider)

      @own_provider = begin
        Sandbox.chaos_provider_for(agent)
      rescue KeyError
        nil
      end
    end

    def api_key?(provider)
      return false if house_funded?

      key = agent.account.ai_api_key(provider)
      key.present? && !key.start_with?("<")
    end

    def house_funded?
      HouseInference::Offering.find(agent.model_id).present?
    end

  end
end
