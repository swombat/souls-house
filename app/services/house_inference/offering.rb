module HouseInference
  # Payment is an explicit model choice. Never retrofit funding onto existing
  # personal routes, or change the provider under an existing offering's ID.
  class Offering

    DEEPSEEK_MODEL_ID = 'house/deepseek-v4.1-flash'.freeze
    HAIKU_MODEL_ID = 'house/claude-haiku-5.5'.freeze
    # What a new house-funded resident starts on. Existing residents keep theirs.
    DEFAULT_MODEL_ID = HAIKU_MODEL_ID

    # The house's recommendation comes first; the picker keeps this order.
    OFFERINGS = {
      # Anthropic's own endpoint. Prompts over 100k tokens are billed at a
      # long-context rate ($0.50/M in, $2.50/M out on 2026-10-08), so the price
      # caps sit above that tier rather than refusing long conversations, and
      # the reservation covers a full context at the caps (about $0.65).
      HAIKU_MODEL_ID => {
        label: 'Claude Haiku 5.5 · On the house',
        upstream_model: 'anthropic/claude-haiku-5.5',
        provider: 'anthropic',
        context_tokens: 1_000_000,
        max_output_tokens: 16_384,
        max_price: { prompt: 0.6, completion: 3.0 },
        reservation_usd: BigDecimal('0.75')
      }.freeze,
      DEEPSEEK_MODEL_ID => {
        label: 'DeepSeek V4.1 Flash · On the house',
        upstream_model: 'deepseek/deepseek-v4.1-flash',
        provider: 'fireworks/us',
        context_tokens: 1_048_576,
        max_output_tokens: 16_384,
        max_price: { prompt: 0.5, completion: 2.0 },
        reservation_usd: BigDecimal('0.75')
      }.freeze
    }.freeze

    def self.find(model_id) = OFFERINGS[model_id]

    # A dedicated house-inference key wins. Otherwise fall back to the house's
    # own OpenRouter token (credentials.ai.openrouter.api_token). House-funded
    # spend on either key is still capped by HOUSE_INFERENCE_MONTHLY_LIMIT_USD
    # and metered per call in the ledger.
    def self.key
      ENV['HOUSE_INFERENCE_OPENROUTER_API_KEY'].presence ||
        Rails.application.credentials.dig(:house_inference, :openrouter_api_key).presence ||
        Rails.application.credentials.dig(:ai, :openrouter, :api_token).presence
    end

    def self.configured? = key.present?
    def self.month = Time.now.utc.to_date.beginning_of_month
    def self.global_limit = BigDecimal(ENV.fetch('HOUSE_INFERENCE_MONTHLY_LIMIT_USD', '300'))

    def self.models
      OFFERINGS.map { |id, config| { model_id: id, label: config[:label], group: 'On the house' } }
    end

  end
end
