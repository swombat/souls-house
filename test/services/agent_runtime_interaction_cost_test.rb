require "test_helper"

class AgentRuntimeInteractionCostTest < ActiveSupport::TestCase

  test "estimates direct Anthropic cost with one hour cache pricing" do
    interaction = build_interaction(
      provider: "anthropic",
      model: "claude-fable-5",
      cache_ttl: "1h",
      uncached_input_tokens: 100_000,
      cache_creation_input_tokens: 20_000,
      cache_read_input_tokens: 500_000,
      output_tokens: 10_000,
      reasoning_output_tokens: 2_000
    )

    cost = interaction.estimated_cost

    assert_equal "estimated", cost[:status]
    assert_equal "direct_api", cost[:pricing_source]
    assert_equal "anthropic/claude-fable-5", cost[:pricing_model]
    assert_equal "2026-08-15", cost[:pricing_as_of]
    assert_equal "2.4", cost[:amount_usd]
    assert_equal "0.4", cost.dig(:components_usd, :cache_creation_input)
    assert_equal "0.5", cost.dig(:components_usd, :cache_read_input)
  end

  test "estimates Claude Opus 5 cost" do
    interaction = build_interaction(
      provider: "anthropic",
      model: "claude-opus-5",
      uncached_input_tokens: 1_000_000,
      output_tokens: 1_000_000
    )

    cost = interaction.estimated_cost

    assert_equal "estimated", cost[:status]
    assert_equal "anthropic/claude-opus-5", cost[:pricing_model]
    assert_equal "30.0", cost[:amount_usd]
  end

  test "uses OpenRouter pricing source for routed models" do
    interaction = build_interaction(
      provider: "openrouter",
      model: "deepseek/deepseek-v4-pro",
      uncached_input_tokens: 1_000_000,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 1_000_000
    )

    cost = interaction.estimated_cost

    assert_equal "openrouter", cost[:pricing_source]
    assert_equal "1.305", cost[:amount_usd]
  end

  test "does not double charge reasoning tokens already included in output" do
    interaction = build_interaction(
      provider: "openai",
      model: "gpt-5.5",
      uncached_input_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 100_000,
      reasoning_output_tokens: 80_000
    )

    assert_equal "3.0", interaction.estimated_cost[:amount_usd]
  end

  test "uses model-specific OpenRouter cache rates" do
    interaction = build_interaction(
      provider: "openrouter",
      model: "openai/gpt-4o",
      uncached_input_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000,
      output_tokens: 0
    )

    assert_equal "1.25", interaction.estimated_cost[:amount_usd]
  end

  test "estimates Gemini 3.7 Flash cost with direct cache pricing" do
    interaction = build_interaction(
      provider: "gemini",
      model: "gemini-3.7-flash",
      uncached_input_tokens: 1_000_000,
      cache_creation_input_tokens: 1_000_000,
      cache_read_input_tokens: 1_000_000,
      output_tokens: 1_000_000
    )

    cost = interaction.estimated_cost

    assert_equal "estimated", cost[:status]
    assert_equal "google/gemini-3.7-flash", cost[:pricing_model]
    assert_equal "4.74166667", cost[:amount_usd]
    assert_equal "0.075", cost.dig(:components_usd, :cache_read_input)
  end

  test "estimates Grok 4.6 cost with cached input pricing" do
    interaction = build_interaction(
      provider: "xai",
      model: "grok-4.6",
      uncached_input_tokens: 1_000_000,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000,
      output_tokens: 1_000_000
    )

    cost = interaction.estimated_cost

    assert_equal "estimated", cost[:status]
    assert_equal "x-ai/grok-4.6", cost[:pricing_model]
    assert_equal "8.5", cost[:amount_usd]
    assert_equal "0.5", cost.dig(:components_usd, :cache_read_input)
  end

  test "leaves cost unavailable for untrusted usage or unknown models" do
    untrusted = build_interaction(
      telemetry_schema_version: nil,
      usage_scope: nil,
      usage_complete: nil,
      provider: "anthropic",
      model: "claude-fable-5"
    )
    unknown = build_interaction(provider: "other", model: "surprise-model")

    assert_nil untrusted.estimated_cost[:amount_usd]
    assert_match(/not trigger-local/, untrusted.estimated_cost[:note])
    assert_nil unknown.estimated_cost[:amount_usd]
    assert_match(/no price/, unknown.estimated_cost[:note])
  end

  test "prices current Nexus models under both catalogue and direct IDs" do
    {
      "openai/gpt-6-astra" => [ "gpt-6-astra", "73.5", "12.5", "1.0" ],
      "openai/gpt-6-sol" => [ "gpt-6-sol", "14.7", "2.5", "0.2" ],
      "openai/gpt-6-luna" => [ "gpt-6-luna", "0.735", "0.125", "0.01" ],
      "anthropic/claude-opus-5.5" => [ "claude-opus-5-5", "29.2", "5.0", "0.2" ],
      "google/gemini-3.8-flash" => [ "gemini-3.8-flash", "5.325", "0.75", "0.075" ]
    }.each do |catalogue_id, (direct_id, amount, write, read)|
      assert_equal direct_id, Chat.provider_model_id(catalogue_id)
      [ catalogue_id, direct_id ].each do |model|
        cost = build_interaction(
          model: model, started_at: Time.utc(2026, 9, 27),
          uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 1_000_000,
          cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
        ).estimated_cost
        assert_equal "estimated", cost[:status], model
        assert_equal amount, cost[:amount_usd], model
        assert_equal write, cost.dig(:components_usd, :cache_creation_input), model
        assert_equal read, cost.dig(:components_usd, :cache_read_input), model
        assert_equal "2026-09-27", cost[:pricing_as_of]
      end
    end
  end

  test "Haiku 5.5 is priced under catalogue, direct and dotted IDs" do
    assert_equal "claude-haiku-5-5", Chat.provider_model_id("anthropic/claude-haiku-5.5")
    [ "anthropic/claude-haiku-5.5", "claude-haiku-5-5", "claude-haiku-5.5" ].each do |model|
      cost = build_interaction(
        model: model,
        uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 1_000_000,
        cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
      ).estimated_cost
      assert_equal "estimated", cost[:status], model
      assert_equal "0.735", cost[:amount_usd], model
      assert_equal "0.125", cost.dig(:components_usd, :cache_creation_input), model
      assert_equal "0.01", cost.dig(:components_usd, :cache_read_input), model
    end
  end

  test "Qwen3.8 Omni Flash is priced from the routed Alibaba endpoint" do
    cost = build_interaction(
      provider: "openrouter", model: "qwen/qwen3.8-omni-flash",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
    ).estimated_cost
    assert_equal "estimated", cost[:status]
    assert_equal "0.636", cost[:amount_usd]
    assert_equal "0.016", cost.dig(:components_usd, :cache_read_input)
  end

  test "October Qwen and GLM prices: input, output and cache read per rule" do
    {
      "qwen/qwen3.8-max-0902" => [ "qwen/qwen3.8-max", "8.25", "0.25" ],
      "qwen3.8-max" => [ "qwen/qwen3.8-max", "8.25", "0.25" ],
      "qwen/qwen3.8-max-prime" => [ "qwen/qwen3.8-max-prime", "16.5", "0.5" ],
      "z-ai/glm-5.3" => [ "z-ai/glm-5.3", "1.5388", "0.0689" ],
      "glm-5.3" => [ "z-ai/glm-5.3", "1.5388", "0.0689" ],
      "z-ai/glm-5.3-prime" => [ "z-ai/glm-5.3-prime", "12.16", "0.56" ]
    }.each do |model, (pricing_model, total, cache_read)|
      cost = build_interaction(
        provider: "openrouter", model: model,
        uncached_input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000,
        output_tokens: 1_000_000
      ).estimated_cost
      assert_equal "estimated", cost[:status], model
      assert_equal pricing_model, cost[:pricing_model], model
      assert_equal "2026-10-26", cost[:pricing_as_of], model
      assert_equal total, cost[:amount_usd], model
      assert_equal cache_read, cost.dig(:components_usd, :cache_read_input), model
    end
  end

  test "October price rules do not swallow neighbouring Qwen and GLM IDs" do
    %w[qwen/qwen3.8-max-prime-0902 qwen/qwen3.8-max-preview z-ai/glm-5.3-flash
       z-ai/glm-5.3-flashx z-ai/glm-5.3-prime-turbo].each do |model|
      assert_nil build_interaction(provider: "openrouter", model: model).estimated_cost[:amount_usd], model
    end
  end

  test "Gemini 4 Argon uses launch pricing until December and doubles after" do
    launch = build_interaction(
      provider: "openrouter", model: "google/gemini-4-argon",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000,
      started_at: Time.zone.parse("2026-10-13 12:00")
    ).estimated_cost
    assert_equal "estimated", launch[:status]
    assert_equal "12.1", launch[:amount_usd]
    assert_equal "0.1", launch.dig(:components_usd, :cache_read_input)

    later = build_interaction(
      provider: "gemini", model: "gemini-4-argon",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000,
      started_at: Time.zone.parse("2026-12-01 12:00")
    ).estimated_cost
    assert_equal "24.2", later[:amount_usd]
  end

  test "Muse Wonder is priced from the routed Meta endpoint" do
    cost = build_interaction(
      provider: "openrouter", model: "meta/muse-wonder",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
    ).estimated_cost
    assert_equal "estimated", cost[:status]
    assert_equal "24.2", cost[:amount_usd]
    assert_equal "0.2", cost.dig(:components_usd, :cache_read_input)
  end

  test "DeepSeek V4.1 Flash 1017 is priced from the DeepSeek endpoint off-peak rate" do
    cost = build_interaction(
      provider: "openrouter", model: "deepseek/deepseek-v4.1-flash-1017",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
    ).estimated_cost
    assert_equal "estimated", cost[:status]
    assert_equal "0.753", cost[:amount_usd]
    assert_equal "0.003", cost.dig(:components_usd, :cache_read_input)
  end

  test "MiniMax M3.1 Flash is priced from the MiniMax endpoint" do
    cost = build_interaction(
      provider: "openrouter", model: "minimax/minimax-m3.1-flash",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
    ).estimated_cost
    assert_equal "estimated", cost[:status]
    assert_equal "0.765", cost[:amount_usd]
    assert_equal "0.015", cost.dig(:components_usd, :cache_read_input)
  end

  test "Kimi K3.1 Pro is priced from the Moonshot AI standard endpoint" do
    cost = build_interaction(
      provider: "openrouter", model: "moonshotai/kimi-k3.1-pro",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
    ).estimated_cost
    assert_equal "estimated", cost[:status]
    assert_equal "12.2", cost[:amount_usd]
    assert_equal "0.2", cost.dig(:components_usd, :cache_read_input)
  end

  test "Mercury 3 is priced at Inception's launch rate" do
    cost = build_interaction(
      provider: "openrouter", model: "inception/mercury-3",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
    ).estimated_cost
    assert_equal "estimated", cost[:status]
    assert_equal "0.46", cost[:amount_usd]
    assert_equal "0.01", cost.dig(:components_usd, :cache_read_input)
  end

  test "Muse Spark Open is priced from the routed Modal endpoint" do
    cost = build_interaction(
      provider: "openrouter", model: "meta/muse-spark-open",
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
    ).estimated_cost
    assert_equal "estimated", cost[:status]
    assert_equal "5.65", cost[:amount_usd]
    assert_equal "0.15", cost.dig(:components_usd, :cache_read_input)
  end

  test "Opus 5.5 supports dotted runtime ID and one hour cache writes" do
    cost = build_interaction(
      provider: "anthropic", model: "claude-opus-5.5", cache_ttl: "1h",
      cache_creation_input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000
    ).estimated_cost

    assert_equal "8.2", cost[:amount_usd]
  end

  test "Gemini 3.8 uses the routed catalogue cache write rate only on OpenRouter" do
    cost = build_interaction(
      provider: "openrouter", model: "google/gemini-3.8-flash", started_at: Time.utc(2026, 9, 27),
      uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 1_000_000,
      cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000
    ).estimated_cost

    assert_equal "openrouter", cost[:pricing_source]
    assert_equal "4.61666667", cost[:amount_usd]
  end

  test "Gemini promotional rates follow the interaction date not the report date" do
    travel_to Time.utc(2027, 2, 1) do
      [ [ Time.utc(2026, 12, 31, 23, 59, 59), "4.575" ],
        [ Time.utc(2027, 1, 1), "9.15" ] ].each do |started_at, amount|
        cost = build_interaction(
          model: "gemini-3.8-flash", started_at: started_at,
          uncached_input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000,
          output_tokens: 1_000_000
        ).estimated_cost
        assert_equal amount, cost[:amount_usd]
      end
    end
  end

  test "new pricing does not guess Pro aliases or missing token categories" do
    %w[openai/gpt-6-astra-pro openai/gpt-6-sol-pro openai/gpt-6-luna-pro].each do |model|
      assert_nil build_interaction(model: model).estimated_cost[:amount_usd]
    end
    cost = build_interaction(model: "gpt-6-astra", cache_read_input_tokens: nil).estimated_cost
    assert_nil cost[:amount_usd]
    assert_match(/token categories are unknown/, cost[:note])
  end

  private

  def build_interaction(**attributes)
    AgentRuntimeInteraction.new(
      {
        agent: agents(:research_assistant),
        trigger_kind: "conversation",
        started_at: Time.current,
        telemetry_schema_version: 1,
        usage_scope: "trigger",
        usage_complete: true,
        uncached_input_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        output_tokens: 0
      }.merge(attributes)
    )
  end

end
