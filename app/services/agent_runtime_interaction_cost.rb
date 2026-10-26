class AgentRuntimeInteractionCost

  PRICING_AS_OF = Date.new(2026, 8, 15)
  UPDATED_PRICING_AS_OF = Date.new(2026, 9, 27)
  UPDATED_MODELS = %w[
    anthropic/claude-opus-5.5 openai/gpt-6-astra openai/gpt-6-sol
    openai/gpt-6-luna google/gemini-3.8-flash
  ].freeze
  OCTOBER_PRICING_AS_OF = Date.new(2026, 10, 26)
  OCTOBER_MODELS = %w[
    qwen/qwen3.8-max qwen/qwen3.8-max-prime z-ai/glm-5.3 z-ai/glm-5.3-prime
  ].freeze
  TOKENS_PER_MILLION = BigDecimal("1000000")

  # Public list prices in USD per million tokens, taken from the route's
  # provider pricing or the OpenRouter catalog on PRICING_AS_OF.
  # UPDATED_MODELS were reverified separately; sources and estimate limits
  # are recorded in docs/interaction-cost-pricing.md.
  #
  # Keep the rules ordered from most specific to least specific.
  PRICE_RULES = [
    [ /\A(?:anthropic\/)?claude-opus-5[-.]5\z/, "anthropic/claude-opus-5.5", 4, 20 ],
    [ /(?:anthropic\/)?claude-opus-5\z/, "anthropic/claude-opus-5", 5, 25 ],
    [ /(?:anthropic\/)?claude-fable-5/, "anthropic/claude-fable-5", 10, 50 ],
    [ /(?:anthropic\/)?claude-sonnet-5/, "anthropic/claude-sonnet-5", 2, 10 ],
    [ /(?:anthropic\/)?claude-opus-4[-.]8/, "anthropic/claude-opus-4.8", 5, 25 ],
    [ /(?:anthropic\/)?claude-opus-4[-.]7/, "anthropic/claude-opus-4.7", 5, 25 ],
    [ /(?:anthropic\/)?claude-opus-4[-.]6/, "anthropic/claude-opus-4.6", 5, 25 ],
    [ /(?:anthropic\/)?claude-opus-4[-.]5/, "anthropic/claude-opus-4.5", 5, 25 ],
    [ /(?:anthropic\/)?claude-sonnet-4[-.]6/, "anthropic/claude-sonnet-4.6", 3, 15 ],
    [ /(?:anthropic\/)?claude-sonnet-4[-.]5/, "anthropic/claude-sonnet-4.5", 3, 15 ],
    [ /\A(?:anthropic\/)?claude-haiku-5[-.]5\z/, "anthropic/claude-haiku-5.5", 0.1, 0.5 ],
    [ /(?:anthropic\/)?claude-haiku-4[-.]5/, "anthropic/claude-haiku-4.5", 1, 5 ],
    [ /(?:anthropic\/)?claude-opus-4[-.]1/, "anthropic/claude-opus-4.1", 15, 75 ],
    [ /(?:anthropic\/)?claude-opus-4(?:-\d{8})?\z/, "anthropic/claude-opus-4", 15, 75 ],
    [ /(?:anthropic\/)?claude-sonnet-4(?:-\d{8})?\z/, "anthropic/claude-sonnet-4", 3, 15 ],

    [ /\A(?:openai\/)?gpt-6-astra\z/, "openai/gpt-6-astra", 10, 50 ],
    [ /\A(?:openai\/)?gpt-6\.1-sol\z/, "openai/gpt-6.1-sol", 2, 10 ],
    [ /\A(?:openai\/)?gpt-6-sol\z/, "openai/gpt-6-sol", 2, 10 ],
    [ /\A(?:openai\/)?gpt-6-luna\z/, "openai/gpt-6-luna", 0.1, 0.5 ],
    [ /(?:openai\/)?gpt-5\.6-sol(?:-pro)?\z/, "openai/gpt-5.6-sol", 5, 30 ],
    [ /(?:openai\/)?gpt-5\.6-terra(?:-pro)?\z/, "openai/gpt-5.6-terra", 2.5, 15 ],
    [ /(?:openai\/)?gpt-5\.6-luna(?:-pro)?\z/, "openai/gpt-5.6-luna", 1, 6 ],
    [ /(?:openai\/)?gpt-5\.5-pro\z/, "openai/gpt-5.5-pro", 30, 180 ],
    [ /(?:openai\/)?gpt-5\.5\z/, "openai/gpt-5.5", 5, 30 ],
    [ /(?:openai\/)?gpt-5\.4-mini\z/, "openai/gpt-5.4-mini", 0.75, 4.5 ],
    [ /(?:openai\/)?gpt-5\.4-nano\z/, "openai/gpt-5.4-nano", 0.2, 1.25 ],
    [ /(?:openai\/)?gpt-5\.4\z/, "openai/gpt-5.4", 2.5, 15 ],
    [ /(?:openai\/)?gpt-5\.3-(?:chat|codex)\z/, "openai/gpt-5.3", 1.75, 14 ],
    [ /(?:openai\/)?gpt-5\.2(?:-chat|-codex)?\z/, "openai/gpt-5.2", 1.75, 14 ],
    [ /(?:openai\/)?gpt-5\.1-codex-mini\z/, "openai/gpt-5.1-codex-mini", 0.25, 2 ],
    [ /(?:openai\/)?gpt-5\.1(?:-chat|-codex|-codex-max)?\z/, "openai/gpt-5.1", 1.25, 10 ],
    [ /(?:openai\/)?gpt-5-mini\z/, "openai/gpt-5-mini", 0.25, 2 ],
    [ /(?:openai\/)?gpt-5-nano\z/, "openai/gpt-5-nano", 0.05, 0.4 ],
    [ /(?:openai\/)?gpt-5(?:-chat|-codex)?\z/, "openai/gpt-5", 1.25, 10 ],
    [ /(?:openai\/)?gpt-4\.1-mini\z/, "openai/gpt-4.1-mini", 0.4, 1.6 ],
    [ /(?:openai\/)?gpt-4\.1-nano\z/, "openai/gpt-4.1-nano", 0.1, 0.4 ],
    [ /(?:openai\/)?gpt-4\.1\z/, "openai/gpt-4.1", 2, 8 ],
    [ /(?:openai\/)?gpt-4o-mini(?:-\d{4}-\d{2}-\d{2})?\z/, "openai/gpt-4o-mini", 0.15, 0.6 ],
    [ /(?:openai\/)?gpt-4o(?:-\d{4}-\d{2}-\d{2})?\z/, "openai/gpt-4o", 2.5, 10 ],

    [ /\A(?:google\/)?gemini-4-argon\z/, "google/gemini-4-argon", 2, 10 ],
    [ /\A(?:google\/)?gemini-3\.8-flash\z/, "google/gemini-3.8-flash", 0.75, 3.75 ],
    [ /(?:google\/)?gemini-3\.7-flash\z/, "google/gemini-3.7-flash", 0.75, 3.75 ],
    [ /(?:google\/)?gemini-3\.5-flash\z/, "google/gemini-3.5-flash", 1.5, 9 ],
    [ /(?:google\/)?gemini-3\.1-pro-preview\z/, "google/gemini-3.1-pro-preview", 2, 12 ],
    [ /(?:google\/)?gemini-3\.1-flash-lite\z/, "google/gemini-3.1-flash-lite", 0.25, 1.5 ],
    [ /(?:google\/)?gemini-3-flash-preview\z/, "google/gemini-3-flash-preview", 0.5, 3 ],
    [ /(?:google\/)?gemini-2\.5-pro\z/, "google/gemini-2.5-pro", 1.25, 10 ],
    [ /(?:google\/)?gemini-2\.5-flash-lite\z/, "google/gemini-2.5-flash-lite", 0.1, 0.4 ],
    [ /(?:google\/)?gemini-2\.5-flash\z/, "google/gemini-2.5-flash", 0.3, 2.5 ],

    [ /(?:x-ai\/)?grok-4\.6\z/, "x-ai/grok-4.6", 2, 6 ],
    [ /(?:x-ai\/)?grok-4\.5\z/, "x-ai/grok-4.5", 2, 6 ],
    [ /(?:x-ai\/)?grok-4\.20(?:-multi-agent)?\z/, "x-ai/grok-4.20", 1.25, 2.5 ],
    [ /(?:x-ai\/)?grok-4\.3\z/, "x-ai/grok-4.3", 1.25, 2.5 ],

    [ /deepseek\/deepseek-v4-pro\z/, "deepseek/deepseek-v4-pro", 0.435, 0.87 ],
    [ /\A(?:deepseek\/)?deepseek-v4\.1-flash-1017\z/, "deepseek/deepseek-v4.1-flash-1017", 0.15, 0.6 ],
    [ /mistralai\/mistral-large-2512\z/, "mistralai/mistral-large-2512", 0.5, 1.5 ],
    [ /\A(?:meta\/)?muse-wonder\z/, "meta/muse-wonder", 4, 20 ],
    [ /\A(?:meta\/)?muse-spark-open\z/, "meta/muse-spark-open", 1.25, 4.25 ],
    [ /meta-llama\/llama-4-maverick\z/, "meta-llama/llama-4-maverick", 0.2, 0.8 ],
    [ /\A(?:minimax\/)?minimax-m3\.1-flash\z/, "minimax/minimax-m3.1-flash", 0.15, 0.6 ],
    [ /\A(?:inception\/)?mercury-3\z/, "inception/mercury-3", 0.1, 0.35 ],
    [ /minimax\/minimax-m3\z/, "minimax/minimax-m3", 0.3, 1.2 ],
    [ /\A(?:moonshotai\/)?kimi-k3\.1-pro\z/, "moonshotai/kimi-k3.1-pro", 2, 10 ],
    [ /moonshotai\/kimi-k2\.7-code\z/, "moonshotai/kimi-k2.7-code", 0.82, 3.75 ],
    [ /\A(?:qwen\/)?qwen3\.8-max-prime\z/, "qwen/qwen3.8-max-prime", 4, 12 ],
    [ /\A(?:qwen\/)?qwen3\.8-max(?:-\d{4})?\z/, "qwen/qwen3.8-max", 2, 6 ],
    [ /qwen\/qwen3\.7-max\z/, "qwen/qwen3.7-max", 1.475, 4.425 ],
    [ /qwen\/qwen3\.8-omni-flash\z/, "qwen/qwen3.8-omni-flash", 0.15, 0.47 ],
    [ /\A(?:z-ai\/)?glm-5\.3-prime\z/, "z-ai/glm-5.3-prime", 2.8, 8.8 ],
    [ /\A(?:z-ai\/)?glm-5\.3\z/, "z-ai/glm-5.3", 0.0699, 1.4 ],
    [ /z-ai\/glm-5\.2\z/, "z-ai/glm-5.2", 0.8218, 2.5828 ]
  ].map do |pattern, model, input, output|
    {
      pattern: pattern,
      model: model,
      input: BigDecimal(input.to_s),
      output: BigDecimal(output.to_s)
    }.freeze
  end.freeze

  CACHE_READ_RATES = {
    "google/gemini-4-argon" => 0.1,
    "anthropic/claude-opus-5.5" => 0.2,
    "google/gemini-3.8-flash" => 0.075,
    "openai/gpt-4.1" => 0.5,
    "openai/gpt-4.1-mini" => 0.1,
    "openai/gpt-4.1-nano" => 0.025,
    "openai/gpt-4o" => 1.25,
    "openai/gpt-4o-mini" => 0.075,
    "google/gemini-3.7-flash" => 0.075,
    "google/gemini-3.5-flash" => 0.15,
    "google/gemini-3.1-pro-preview" => 0.2,
    "google/gemini-3.1-flash-lite" => 0.025,
    "google/gemini-3-flash-preview" => 0.05,
    "google/gemini-2.5-pro" => 0.125,
    "google/gemini-2.5-flash" => 0.03,
    "google/gemini-2.5-flash-lite" => 0.01,
    "deepseek/deepseek-v4-pro" => 0.003625,
    "deepseek/deepseek-v4.1-flash-1017" => 0.003,
    "mistralai/mistral-large-2512" => 0.05,
    "meta/muse-wonder" => 0.2,
    "meta/muse-spark-open" => 0.15,
    "minimax/minimax-m3" => 0.06,
    "minimax/minimax-m3.1-flash" => 0.015,
    "inception/mercury-3" => 0.01,
    "moonshotai/kimi-k3.1-pro" => 0.2,
    "moonshotai/kimi-k2.7-code" => 0.16,
    "qwen/qwen3.7-max" => 0.295,
    "qwen/qwen3.8-omni-flash" => 0.016,
    "qwen/qwen3.8-max-prime" => 0.5,
    "qwen/qwen3.8-max" => 0.25,
    "z-ai/glm-5.3-prime" => 0.56,
    "z-ai/glm-5.3" => 0.0689,
    "z-ai/glm-5.2" => 0.15262,
    "x-ai/grok-4.6" => 0.5
  }.transform_values { |rate| BigDecimal(rate.to_s) }.freeze

  CACHE_WRITE_RATES = {
    "openai/gpt-6-astra" => 12.5,
    "openai/gpt-6-sol" => 2.5,
    "openai/gpt-6-luna" => 0.125,
    "google/gemini-3.7-flash" => 0.16666666666666667,
    "google/gemini-3.5-flash" => 0.08333333333333334,
    "google/gemini-3.1-pro-preview" => 0.375,
    "google/gemini-3.1-flash-lite" => 0.08333333333333334,
    "google/gemini-3-flash-preview" => 0.08333333333333334,
    "google/gemini-2.5-pro" => 0.375,
    "google/gemini-2.5-flash" => 0.08333333333333334,
    "google/gemini-2.5-flash-lite" => 0.08333333333333334,
    "qwen/qwen3.7-max" => 1.84375
  }.transform_values { |rate| BigDecimal(rate.to_s) }.freeze

  def initialize(interaction)
    @interaction = interaction
  end

  def call
    return unavailable("usage telemetry is not trigger-local") unless interaction.local_usage?

    price = price_for(interaction.model)
    return unavailable("no price is configured for this model") unless price

    components = {
      uncached_input: component_cost(interaction.uncached_input_tokens, price[:input]),
      cache_creation_input: component_cost(interaction.cache_creation_input_tokens, cache_creation_rate(price)),
      cache_read_input: component_cost(interaction.cache_read_input_tokens, cache_read_rate(price)),
      output: component_cost(interaction.output_tokens, price[:output])
    }
    return unavailable("one or more required token categories are unknown", price) if components.value?(nil)

    {
      status: "estimated",
      amount_usd: decimal(components.values.sum),
      currency: "USD",
      pricing_source: interaction.provider == "openrouter" ? "openrouter" : "direct_api",
      pricing_model: price[:model],
      pricing_as_of: pricing_as_of(price),
      components_usd: components.transform_values { |value| decimal(value) },
      note: "Reasoning tokens are included in output tokens and are not charged twice."
    }
  end

  private

  attr_reader :interaction

  def price_for(model)
    price = PRICE_RULES.find { |rule| model.to_s.match?(rule[:pattern]) }
    # Use the interaction date, not today's date, so historical promotional
    # usage retains its rate. Storage time is not present in token telemetry.
    if price && price[:model] == "google/gemini-4-argon" &&
        interaction.started_at.to_date >= Date.new(2026, 12, 1)
      price = price.merge(input: price[:input] * 2, output: price[:output] * 2,
        cache_read: BigDecimal("0.2"))
    end
    if price && price[:model] == "google/gemini-3.8-flash" &&
        interaction.started_at.to_date >= Date.new(2027, 1, 1)
      price = price.merge(input: price[:input] * 2, output: price[:output] * 2,
        cache_read: BigDecimal("0.15"))
    end
    price
  end

  def pricing_as_of(price)
    model = price&.dig(:model)
    date = if OCTOBER_MODELS.include?(model) then OCTOBER_PRICING_AS_OF
    elsif UPDATED_MODELS.include?(model) then UPDATED_PRICING_AS_OF
    else PRICING_AS_OF
    end
    date.iso8601
  end

  def cache_creation_rate(price)
    if interaction.provider == "openrouter" && price[:model] == "google/gemini-3.8-flash"
      # The routed catalogue quotes a token write rate; the direct API instead
      # documents storage by token-hour. Do not apply one route's rate to both.
      return BigDecimal("0.0416666666666667") * (price[:input] / BigDecimal("0.75"))
    end

    if interaction.provider == "openrouter" && price[:model] == "google/gemini-4-argon"
      # Routed catalogue write rate at launch ($0.1875 at $2 input), scaled
      # with the scheduled December price change like Gemini 3.8 Flash.
      return BigDecimal("0.1875") * (price[:input] / BigDecimal("2"))
    end

    if anthropic?
      return price[:input] * (interaction.cache_ttl == "1h" ? 2 : BigDecimal("1.25"))
    end

    CACHE_WRITE_RATES.fetch(price[:model], price[:input])
  end

  def cache_read_rate(price)
    return price[:cache_read] if price.key?(:cache_read)
    return CACHE_READ_RATES[price[:model]] if CACHE_READ_RATES.key?(price[:model])
    return price[:input] * BigDecimal("0.1") if anthropic? || openai? || gemini?
    return price[:input] * BigDecimal("0.15") if xai?

    price[:input]
  end

  def anthropic?
    interaction.provider == "anthropic" || interaction.model.to_s.start_with?("anthropic/", "claude-")
  end

  def openai?
    interaction.provider == "openai" || interaction.model.to_s.start_with?("openai/", "gpt-")
  end

  def gemini?
    interaction.provider == "gemini" || interaction.model.to_s.start_with?("google/", "gemini-")
  end

  def xai?
    interaction.provider == "xai" || interaction.model.to_s.start_with?("x-ai/", "grok-")
  end

  def component_cost(tokens, rate_per_million)
    return if tokens.nil?

    BigDecimal(tokens.to_s) * rate_per_million / TOKENS_PER_MILLION
  end

  def decimal(value)
    value.round(8).to_s("F")
  end

  def unavailable(reason, price = nil)
    {
      status: "unavailable",
      amount_usd: nil,
      currency: "USD",
      pricing_source: nil,
      pricing_model: price&.dig(:model),
      pricing_as_of: pricing_as_of(price),
      components_usd: nil,
      note: reason
    }
  end

end
