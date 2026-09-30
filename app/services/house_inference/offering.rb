module HouseInference
  # Payment is an explicit model choice. Never retrofit funding onto existing
  # personal routes, or change the provider under an existing offering's ID.
  class Offering

    MODEL_ID = 'house/deepseek-v4.1-flash'.freeze
    OFFERINGS = {
      MODEL_ID => {
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
    def self.key = ENV['HOUSE_INFERENCE_OPENROUTER_API_KEY'].presence || Rails.application.credentials.dig(:house_inference, :openrouter_api_key)
    def self.configured? = key.present?
    def self.month = Time.now.utc.to_date.beginning_of_month
    def self.global_limit = BigDecimal(ENV.fetch('HOUSE_INFERENCE_MONTHLY_LIMIT_USD', '300'))

    def self.models
      OFFERINGS.map { |id, config| { model_id: id, label: config[:label], group: 'On the house' } }
    end

  end
end
