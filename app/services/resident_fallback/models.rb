# The models a resident may fall back to when its subscription allowance runs
# out (#690), and the bounds each paid call is held to. Like
# HouseInference::Offering, payment is an explicit model choice: a model is
# eligible only when it is listed here with reviewed rates. Nothing is read
# from mutable catalogue data.
#
# Why a call's reservation bounds what settlement can count, per route
# (OpenRouter /models/<id>/endpoints, read on RATES_AS_OF; ROUTE_PRICES below
# keeps that reading and a test checks the rates against it):
#
# - The call is pinned to the model's own vendor (`provider`, with
#   allow_fallbacks false) and `max_price` is the vendor's list price, so
#   OpenRouter can't pick a dearer endpoint of it: the regional ones (1.1x)
#   and the "fast" ones (2x) are excluded by price.
# - Input can be billed above the prompt rate: Anthropic's cache writes
#   (1.25x, or 2x for the one-hour cache) and OpenAI's long-context tier
#   (above 272k prompt tokens). `max_price` doesn't cover those, so the
#   reservation's input rate is the dearest input rate the route has.
# - Output likewise takes the dearest completion rate (OpenAI's long-context
#   tier raises it too). Reasoning is billed as completion and counted inside
#   max_tokens.
# - With BYOK OpenRouter adds its fee (5% of what the call would have cost on
#   its own credits) to the provider's charge; usage.cost then reports both
#   (HouseInference::UsageCost). Both rates carry FEE_FACTOR for it.
# - Tokens are bounded by bytes: the input bound is the request's size in
#   bytes plus framing (HouseInference::Request.input_bound), and no token is
#   shorter than one byte.
#
# Web search is the one price outside tokens; the gateway allows no plugins,
# so nothing can call it.
module ResidentFallback
  module Models

    RATES_AS_OF = Date.new(2026, 11, 11)
    # OpenRouter's BYOK fee (5%), rounded up.
    FEE_FACTOR = BigDecimal("1.06")

    ELIGIBLE = {
      "anthropic/claude-sonnet-5" => {
        upstream_model: "anthropic/claude-sonnet-5",
        provider: "anthropic",
        list_price: { prompt: 2, completion: 10 },
        max_price: { prompt: 2, completion: 10 },
        # One-hour cache write $4/M is the dearest input.
        reservation_rate: { prompt: BigDecimal("4.24"), completion: BigDecimal("10.6") },
        context_tokens: 1_000_000,
        max_output_tokens: 32_000
      }.freeze,
      "anthropic/claude-opus-5.5" => {
        upstream_model: "anthropic/claude-opus-5.5",
        provider: "anthropic",
        list_price: { prompt: 4, completion: 20 },
        max_price: { prompt: 4, completion: 20 },
        # One-hour cache write $8/M.
        reservation_rate: { prompt: BigDecimal("8.48"), completion: BigDecimal("21.2") },
        context_tokens: 1_000_000,
        max_output_tokens: 32_000
      }.freeze,
      "openai/gpt-6-sol" => {
        upstream_model: "openai/gpt-6-sol",
        provider: "openai",
        list_price: { prompt: 2, completion: 10 },
        max_price: { prompt: 2, completion: 10 },
        # Above 272k prompt tokens: cache write $5/M, completion $15/M.
        reservation_rate: { prompt: BigDecimal("5.3"), completion: BigDecimal("15.9") },
        context_tokens: 400_000,
        max_output_tokens: 32_000
      }.freeze
    }.freeze

    # What the pinned vendor endpoint charged per million tokens on
    # RATES_AS_OF, every input-side and output-side rate including tiers.
    ROUTE_PRICES = {
      "anthropic/claude-sonnet-5" => { input: [ 2, 2.5, 4, 0.2 ], output: [ 10 ] },
      "anthropic/claude-opus-5.5" => { input: [ 4, 5, 8, 0.2 ], output: [ 20 ] },
      "openai/gpt-6-sol" => { input: [ 2, 2.5, 0.2, 4, 5, 0.4 ], output: [ 10, 15 ] }
    }.freeze

    TOKENS_PER_MILLION = BigDecimal("1000000")

    module_function

    def find(model_id) = ELIGIBLE[model_id.to_s]

    def label(model_id) = Agent.label_for_model(model_id)

    def choices
      ELIGIBLE.keys.map { |id| { model_id: id, label: label(id) } }
    end

    # The shape HouseInference::Request builds a pinned upstream body from.
    def offering(model_id)
      config = find(model_id) or return
      config.slice(:upstream_model, :provider, :max_price, :context_tokens, :max_output_tokens)
    end

    # Every input token and every allowed output token at the route's
    # dearest rates plus the fee, rounded up (see the top of this file).
    def reservation_usd(model_id, input_bound_tokens:, max_output_tokens:)
      config = find(model_id) or raise ArgumentError, "#{model_id} is not a fallback model"
      rate = config.fetch(:reservation_rate)
      input = BigDecimal(input_bound_tokens.to_s) * rate.fetch(:prompt)
      output = BigDecimal(max_output_tokens.to_s) * rate.fetch(:completion)
      ((input + output) / TOKENS_PER_MILLION).ceil(8)
    end

  end
end
