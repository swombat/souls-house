module Agents
  # The models a resident can be given, grouped as the resident pages show them.
  module ModelCatalogue

    def self.grouped
      (Chat::MODELS + HouseInference::Offering.models).group_by { |m| m[:group] || "Other" }.transform_values do |models|
        models.map do |m|
          reasoning = Chat.reasoning_effort_config(m[:model_id])
          {
            model_id: m[:model_id],
            label: m[:label],
            supports_thinking: m.dig(:thinking, :supported) == true,
            # Whether a conversation may select it (Agent::ModelSwitching).
            switchable: m[:provider_model_id].present? && !HouseInference::Offering.find(m[:model_id]),
            key_provider: key_provider(m[:model_id]),
            reasoning:
          }
        end
      end
    end

    DIRECT_KEY_PROVIDERS = {
      "anthropic/" => "anthropic",
      "openai/" => "openai",
      "google/" => "gemini",
      "x-ai/" => "xai",
      "kimi-code/" => "moonshot"
    }.freeze

    # The account key a resident on this model would use: the model's own
    # provider when ResolvesProvider can route it there directly, otherwise
    # OpenRouter. Nil for house models, which need no key.
    def self.key_provider(model_id)
      model_id = model_id.to_s
      return if HouseInference::Offering.find(model_id)

      if Chat.model_config(model_id)&.dig(:provider_model_id)
        DIRECT_KEY_PROVIDERS.each { |prefix, provider| return provider if model_id.start_with?(prefix) }
      end
      "openrouter"
    end

  end
end
