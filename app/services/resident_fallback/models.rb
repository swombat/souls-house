# The models a resident may fall back to when its subscription allowance runs
# out (#690), and the bounds each paid call is held to. Like
# HouseInference::Offering, payment is an explicit model choice: a model is
# eligible only when it is listed here with reviewed rates. Nothing is read
# from mutable catalogue data.
#
# `max_price` (USD per million tokens) goes to OpenRouter on every call, so a
# provider charging more is never routed to; it is set at twice the list
# price to leave room for long-context tiers. Each call's reservation is
# computed from these caps, so it is a true upper bound on what OpenRouter
# can charge for that call.
module ResidentFallback
  module Models

    RATES_AS_OF = Date.new(2026, 11, 10)

    ELIGIBLE = {
      "anthropic/claude-sonnet-5" => {
        upstream_model: "anthropic/claude-sonnet-5",
        list_price: { prompt: 2, completion: 10 },
        max_price: { prompt: 4, completion: 20 },
        context_tokens: 1_000_000,
        max_output_tokens: 32_000
      }.freeze,
      "anthropic/claude-opus-5.5" => {
        upstream_model: "anthropic/claude-opus-5.5",
        list_price: { prompt: 4, completion: 20 },
        max_price: { prompt: 8, completion: 40 },
        context_tokens: 1_000_000,
        max_output_tokens: 32_000
      }.freeze,
      "openai/gpt-6-sol" => {
        upstream_model: "openai/gpt-6-sol",
        list_price: { prompt: 2, completion: 10 },
        max_price: { prompt: 4, completion: 20 },
        context_tokens: 400_000,
        max_output_tokens: 32_000
      }.freeze
    }.freeze

    TOKENS_PER_MILLION = BigDecimal("1000000")

    module_function

    def find(model_id) = ELIGIBLE[model_id.to_s]

    def label(model_id) = Agent.label_for_model(model_id)

    def choices
      ELIGIBLE.keys.map { |id| { model_id: id, label: label(id) } }
    end

    # The most a single call can cost: every input token and every allowed
    # output token at the caps OpenRouter is told to enforce.
    def reservation_usd(model_id, input_bound_tokens:, max_output_tokens:)
      config = find(model_id) or raise ArgumentError, "#{model_id} is not a fallback model"
      price = config.fetch(:max_price)
      input = BigDecimal(input_bound_tokens.to_s) * BigDecimal(price.fetch(:prompt).to_s)
      output = BigDecimal(max_output_tokens.to_s) * BigDecimal(price.fetch(:completion).to_s)
      ((input + output) / TOKENS_PER_MILLION).ceil(8)
    end

  end
end
