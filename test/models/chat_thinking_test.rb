require "test_helper"

class ChatThinkingTest < ActiveSupport::TestCase

  test "Astra and Gemini 3.8 are top picks and available in their provider groups" do
    {
      "openai/gpt-6-astra" => [ "GPT-6 Astra", "OpenAI", "gpt-6-astra" ],
      "google/gemini-3.8-flash" => [ "Gemini 3.8 Flash", "Google", "gemini-3.8-flash" ]
    }.each do |id, (label, group, provider_id)|
      entries = Chat::MODELS.select { |model| model[:model_id] == id }
      assert_equal [ "Top Models", group ], entries.pluck(:group)
      assert entries.all? { |model| model[:label] == label && model[:provider_model_id] == provider_id }
      assert Chat.supports_thinking?(id)
      assert_equal provider_id, Chat.provider_model_id(id)
    end
    assert Chat.model_config("openai/gpt-5.6-sol")
    assert Chat.model_config("google/gemini-3.7-flash")
    assert Chat.supports_audio_input?("google/gemini-3.8-flash")
  end

  test "new models expose their reasoning profiles" do
    astra = Chat.reasoning_effort_config("openai/gpt-6-astra")
    assert_equal "medium", astra[:default]
    assert_equal %w[low medium high xhigh max ultra], astra[:options].pluck(:value)
    gemini = Chat.reasoning_effort_config("google/gemini-3.8-flash")
    assert_equal "Thinking level", gemini[:label]
    assert_equal %w[minimal low medium high], gemini[:options].pluck(:value)
  end

  test "supports_thinking? returns true for capable models" do
    assert Chat.supports_thinking?("anthropic/claude-opus-4.5")
    assert Chat.supports_thinking?("anthropic/claude-sonnet-4.5")
    assert Chat.supports_thinking?("anthropic/claude-opus-4")
    assert Chat.supports_thinking?("anthropic/claude-sonnet-4")
    assert Chat.supports_thinking?("anthropic/claude-3.7-sonnet")
    assert Chat.supports_thinking?("openai/gpt-5.2")
    assert Chat.supports_thinking?("openai/gpt-5.1")
    assert Chat.supports_thinking?("openai/gpt-5")
    assert Chat.supports_thinking?("google/gemini-3-pro-preview")
    assert Chat.supports_thinking?("x-ai/grok-4.3")
    assert Chat.supports_thinking?("x-ai/grok-4.20")
    assert Chat.supports_thinking?("x-ai/grok-4.20-multi-agent")
  end

  test "supports_thinking? returns false for non-capable models" do
    refute Chat.supports_thinking?("anthropic/claude-3.5-sonnet")
    refute Chat.supports_thinking?("anthropic/claude-3-opus")
    refute Chat.supports_thinking?("anthropic/claude-haiku-4.5")
    refute Chat.supports_thinking?("openai/gpt-4o")
    refute Chat.supports_thinking?("openai/gpt-4o-mini")
    refute Chat.supports_thinking?("openai/gpt-5-mini")
    refute Chat.supports_thinking?("openai/gpt-5-nano")
    refute Chat.supports_thinking?("google/gemini-2.5-pro")
  end

  test "supports_thinking? returns false for unknown models" do
    refute Chat.supports_thinking?("unknown/model")
    refute Chat.supports_thinking?("nonexistent/gpt-10")
    refute Chat.supports_thinking?(nil)
  end

  test "reasoning effort config exposes every Sol level from Chaos" do
    config = Chat.reasoning_effort_config("openai/gpt-5.6-sol")

    assert_equal "low", config[:default]
    assert_equal %w[low medium high xhigh max ultra], config[:options].pluck(:value)
    assert_equal "Ultra", config[:options].last[:label]
  end

  test "reasoning effort config uses Anthropic effort terminology for Fable" do
    config = Chat.reasoning_effort_config("anthropic/claude-fable-5")

    assert_equal "Effort", config[:label]
    assert_equal "high", config[:default]
    assert_equal %w[low medium high xhigh max ultra], config[:options].pluck(:value)
    assert_equal "Ultra", config[:options].last[:label]
  end

  test "reasoning effort config keeps other Anthropic models model-specific" do
    config = Chat.reasoning_effort_config("anthropic/claude-opus-5")

    assert_equal "Effort", config[:label]
    assert_equal %w[low medium high xhigh max], config[:options].pluck(:value)
  end

  test "reasoning effort config uses thinking levels for Gemini" do
    config = Chat.reasoning_effort_config("google/gemini-3.7-flash")

    assert_equal "Thinking level", config[:label]
    assert_equal %w[minimal low medium high], config[:options].pluck(:value)
  end

  test "reasoning effort config uses thinking mode for toggle providers" do
    config = Chat.reasoning_effort_config("qwen/qwen3.7-max")

    assert_equal "Thinking mode", config[:label]
    assert_equal %w[none high], config[:options].pluck(:value)
    assert_equal %w[Off On], config[:options].pluck(:label)
  end

  test "reasoning effort config is absent for models without a configurable setting" do
    assert_nil Chat.reasoning_effort_config("openai/gpt-4o")
  end

  test "requires_direct_api_for_thinking? returns true for Claude 4+ models" do
    assert Chat.requires_direct_api_for_thinking?("anthropic/claude-opus-4.5")
    assert Chat.requires_direct_api_for_thinking?("anthropic/claude-sonnet-4.5")
    assert Chat.requires_direct_api_for_thinking?("anthropic/claude-opus-4")
    assert Chat.requires_direct_api_for_thinking?("anthropic/claude-sonnet-4")
  end

  test "requires_direct_api_for_thinking? returns false for non-Claude 4 models" do
    refute Chat.requires_direct_api_for_thinking?("anthropic/claude-3.7-sonnet")
    refute Chat.requires_direct_api_for_thinking?("anthropic/claude-3.5-sonnet")
    refute Chat.requires_direct_api_for_thinking?("openai/gpt-5.2")
    refute Chat.requires_direct_api_for_thinking?("openai/gpt-5")
    refute Chat.requires_direct_api_for_thinking?("google/gemini-3-pro-preview")
  end

  test "requires_direct_api_for_thinking? returns false for unknown models" do
    refute Chat.requires_direct_api_for_thinking?("unknown/model")
    refute Chat.requires_direct_api_for_thinking?(nil)
  end

  test "provider_model_id returns correct Anthropic model ID for Claude 4.5 Opus" do
    assert_equal "claude-opus-4-5-20251101", Chat.provider_model_id("anthropic/claude-opus-4.5")
  end

  test "provider_model_id returns correct Anthropic model ID for Claude 4.5 Sonnet" do
    assert_equal "claude-sonnet-4-5-20250929", Chat.provider_model_id("anthropic/claude-sonnet-4.5")
  end

  test "provider_model_id returns correct Anthropic model ID for Claude 4 Opus" do
    assert_equal "claude-opus-4-20250514", Chat.provider_model_id("anthropic/claude-opus-4")
  end

  test "provider_model_id returns correct Anthropic model ID for Claude 4 Sonnet" do
    assert_equal "claude-sonnet-4-20250514", Chat.provider_model_id("anthropic/claude-sonnet-4")
  end

  test "provider_model_id falls back to stripping provider prefix for OpenAI models" do
    assert_equal "gpt-5.2", Chat.provider_model_id("openai/gpt-5.2")
    assert_equal "gpt-5", Chat.provider_model_id("openai/gpt-5")
    assert_equal "gpt-4o", Chat.provider_model_id("openai/gpt-4o")
  end

  test "provider_model_id falls back to stripping provider prefix for Google models" do
    assert_equal "gemini-3-pro-preview", Chat.provider_model_id("google/gemini-3-pro-preview")
    assert_equal "gemini-2.5-pro", Chat.provider_model_id("google/gemini-2.5-pro")
  end

  test "provider_model_id returns current direct xAI model IDs for Grok models" do
    assert_equal "grok-4.6", Chat.provider_model_id("x-ai/grok-4.6")
    assert_equal "grok-4.5", Chat.provider_model_id("x-ai/grok-4.5")
    assert_equal "grok-4.3", Chat.provider_model_id("x-ai/grok-4.3")
    assert_equal "grok-4.20-0309-reasoning", Chat.provider_model_id("x-ai/grok-4.20")
    assert_equal "grok-4.20-multi-agent-0309", Chat.provider_model_id("x-ai/grok-4.20-multi-agent")
  end

  test "provider_model_id handles models without provider prefix" do
    assert_equal "gpt-5", Chat.provider_model_id("gpt-5")
    assert_equal "claude-opus-4", Chat.provider_model_id("claude-opus-4")
  end

  test "model_config returns correct config for known models" do
    config = Chat.model_config("anthropic/claude-opus-4.5")
    assert_not_nil config
    assert_equal "anthropic/claude-opus-4.5", config[:model_id]
    assert_equal "Claude Opus 4.5", config[:label]
    assert_equal "Anthropic", config[:group]
    assert_equal true, config.dig(:thinking, :supported)
    assert_equal true, config.dig(:thinking, :requires_direct_api)
    assert_equal "claude-opus-4-5-20251101", config[:provider_model_id]
  end

  test "model_config returns correct config for models without thinking" do
    config = Chat.model_config("anthropic/claude-3.5-sonnet")
    assert_not_nil config
    assert_equal "anthropic/claude-3.5-sonnet", config[:model_id]
    assert_equal "Claude 3.5 Sonnet", config[:label]
    assert_nil config.dig(:thinking, :supported)
  end

  test "model_config returns nil for unknown models" do
    assert_nil Chat.model_config("unknown/model")
    assert_nil Chat.model_config("fake/gpt-100")
    assert_nil Chat.model_config(nil)
  end

  test "MODELS constant uses stable Grok 4.20 entries instead of beta slugs" do
    model_ids = Chat::MODELS.map { |model| model[:model_id] }

    assert_includes model_ids, "x-ai/grok-4.20"
    assert_includes model_ids, "x-ai/grok-4.20-multi-agent"
    refute model_ids.any? { |model_id| model_id.include?("grok-4.20") && model_id.include?("beta") }
  end

  test "MODELS constant includes contemplative essayist probe OpenRouter models" do
    model_ids = Chat::MODELS.map { |model| model[:model_id] }

    [
      "anthropic/claude-sonnet-4.6",
      "deepseek/deepseek-chat",
      "google/gemini-2.0-flash-001",
      "google/gemini-2.0-flash-lite-001",
      "google/gemini-2.5-flash-lite",
      "google/gemini-3.1-flash-lite",
      "google/gemini-3.5-flash",
      "google/gemma-4-26b-a4b-it",
      "google/gemma-4-31b-it",
      "minimax/minimax-m2",
      "minimax/minimax-m2.7",
      "moonshotai/kimi-coding",
      "moonshotai/kimi-k2-0905",
      "moonshotai/kimi-k2-thinking",
      "moonshotai/kimi-k2.5",
      "moonshotai/kimi-k2.6",
      "openai/gpt-4o-2024-08-06",
      "openai/gpt-5-codex",
      "openai/gpt-5.1-codex",
      "openai/gpt-5.2-codex",
      "openai/gpt-5.3-chat",
      "openai/gpt-5.3-codex",
      "qwen/qwen3-coder-flash",
      "qwen/qwen3-coder-plus",
      "qwen/qwen3-max",
      "qwen/qwen3-max-thinking",
      "qwen/qwen3.5-flash-02-23",
      "qwen/qwen3.5-plus-20260420",
      "qwen/qwen3.6-flash",
      "qwen/qwen3.6-max-preview",
      "qwen/qwen3.6-plus",
      "qwen/qwen3.7-max",
      "x-ai/grok-4-1-fast-non-reasoning",
      "x-ai/grok-4-1-fast-reasoning",
      "x-ai/grok-4.2",
      "z-ai/glm-4.5",
      "z-ai/glm-4.6",
      "z-ai/glm-4.6-coding",
      "z-ai/glm-4.7",
      "z-ai/glm-5.1",
      "z-ai/glm-5.1-coding"
    ].each do |model_id|
      assert_includes model_ids, model_id
    end
  end

  test "Top Models uses Grok 4.6 as the xAI recommendation" do
    top_xai_model = Chat::MODELS.find { |model| model[:group] == "Top Models" && model[:model_id].start_with?("x-ai/") }

    assert_equal "x-ai/grok-4.6", top_xai_model[:model_id]
    assert_equal "grok-4.6", top_xai_model[:provider_model_id]
  end

  test "Top Models includes exactly one latest flagship per lab" do
    top_model_ids = Chat::MODELS
      .select { |model| model[:group] == "Top Models" }
      .map { |model| model[:model_id] }

    assert_equal [
      "openai/gpt-6-astra",
      "anthropic/claude-fable-5",
      "deepseek/deepseek-v4-pro-0813",
      "google/gemini-3.8-flash",
      "x-ai/grok-4.6",
      "mistralai/mistral-large-2512",
      "meta-llama/llama-4-maverick",
      "minimax/minimax-m3",
      "moonshotai/kimi-k3",
      "qwen/qwen3.8-max",
      "z-ai/glm-5.2"
    ], top_model_ids

    assert_equal "OpenAI", Chat.model_config("openai/gpt-5.5")[:group]
    assert_equal "Anthropic", Chat.model_config("anthropic/claude-opus-4.7")[:group]
    assert_equal "DeepSeek", Chat.model_config("deepseek/deepseek-v3.2")[:group]
  end

  test "MODELS constant includes the latest OpenRouter catalog additions" do
    model_ids = Chat::MODELS.map { |model| model[:model_id] }

    [
      "anthropic/claude-opus-5-fast",
      "deepseek/deepseek-v4-flash-0731",
      "deepseek/deepseek-v4-pro-0813",
      "google/gemini-3.5-flash-lite",
      "google/gemini-3.6-flash",
      "google/gemini-3.7-flash",
      "moonshotai/kimi-k3",
      "qwen/qwen3.7-flash",
      "qwen/qwen3.8-2.4t-a95b",
      "qwen/qwen3.8-max",
      "x-ai/grok-4.6"
    ].each do |model_id|
      assert_includes model_ids, model_id
    end
  end

  test "MODELS constant includes thinking metadata for all thinking-capable models" do
    thinking_models = Chat::MODELS.select { |m| m.dig(:thinking, :supported) == true }

    # Verify we have thinking models
    assert thinking_models.any?, "Should have at least one thinking-capable model"

    # Verify all Claude 4+ models have requires_direct_api flag
    claude_4_models = thinking_models.select { |m| m[:model_id].match?(/claude-(opus|sonnet)-4/) }
    claude_4_models.each do |model|
      assert_equal true, model.dig(:thinking, :requires_direct_api),
                   "#{model[:model_id]} should require direct API"
      assert model[:provider_model_id].present?,
                   "#{model[:model_id]} should have provider_model_id"
    end
  end

  test "MODELS constant includes Claude Opus 4.8 direct Anthropic mapping" do
    model = Chat::MODELS.find { |m| m[:model_id] == "anthropic/claude-opus-4.8" }

    assert model, "Claude Opus 4.8 should be available"
    assert_equal "Claude Opus 4.8", model[:label]
    assert_equal "Anthropic", model[:group]
    assert_equal "claude-opus-4-8", model[:provider_model_id]
    assert_equal true, model.dig(:thinking, :supported)
    assert_equal true, model.dig(:thinking, :requires_direct_api)
  end

  test "MODELS constant includes corpus-v2 models added after Claude Opus 4.8" do
    model_ids = Chat::MODELS.map { |model| model[:model_id] }

    [
      "anthropic/claude-fable-5",
      "anthropic/claude-sonnet-5",
      "meta-llama/llama-3.1-70b-instruct",
      "meta-llama/llama-3.1-8b-instruct",
      "meta-llama/llama-3.2-1b-instruct",
      "meta-llama/llama-3.2-11b-vision-instruct",
      "meta-llama/llama-3.2-3b-instruct",
      "meta-llama/llama-3.3-70b-instruct",
      "meta-llama/llama-4-maverick",
      "meta-llama/llama-4-scout",
      "minimax/minimax-m3",
      "mistralai/codestral-2508",
      "mistralai/devstral-2512",
      "mistralai/ministral-14b-2512",
      "mistralai/ministral-3b-2512",
      "mistralai/ministral-8b-2512",
      "mistralai/mistral-large-2512",
      "mistralai/mistral-medium-3",
      "mistralai/mistral-medium-3.1",
      "mistralai/mistral-medium-3-5",
      "mistralai/mistral-nemo",
      "mistralai/mistral-saba",
      "mistralai/mistral-small-24b-instruct-2501",
      "mistralai/mistral-small-2603",
      "mistralai/mistral-small-3.1-24b-instruct",
      "mistralai/mistral-small-3.2-24b-instruct",
      "mistralai/mixtral-8x22b-instruct",
      "moonshotai/kimi-k2.7-code",
      "openai/gpt-3.5-turbo",
      "openai/gpt-4",
      "openai/gpt-4-turbo",
      "openai/gpt-4.1-nano",
      "openai/gpt-4.1-mini",
      "openai/gpt-4o-mini",
      "openai/gpt-5.1-codex-max",
      "openai/gpt-5.1-codex-mini",
      "openai/gpt-5.4-mini",
      "openai/gpt-5.4-nano",
      "openai/gpt-5.6-luna",
      "openai/gpt-5.6-sol",
      "openai/gpt-5.6-terra",
      "openai/gpt-5-mini",
      "openai/gpt-5-nano",
      "openai/gpt-oss-120b",
      "openai/gpt-oss-20b",
      "x-ai/grok-4.20",
      "x-ai/grok-4.20-non-reasoning",
      "x-ai/grok-build-0.1",
      "z-ai/glm-5.2"
    ].each do |model_id|
      assert_includes model_ids, model_id
    end
  end

  test "new direct corpus-v2 models use their verified provider model IDs" do
    assert_equal "claude-sonnet-5", Chat.provider_model_id("anthropic/claude-sonnet-5")
    assert_equal "claude-fable-5", Chat.provider_model_id("anthropic/claude-fable-5")
    %w[
      gpt-5.1-codex-max
      gpt-5.1-codex-mini
      gpt-5.4-mini
      gpt-5.4-nano
      gpt-5.6-sol
      gpt-5.6-terra
      gpt-5.6-luna
    ].each do |model_id|
      assert_equal model_id, Chat.provider_model_id("openai/#{model_id}")
    end
    assert_equal "grok-4.20-0309-reasoning", Chat.provider_model_id("x-ai/grok-4.20")
    assert_equal "grok-4.20-0309-non-reasoning", Chat.provider_model_id("x-ai/grok-4.20-non-reasoning")
    assert_equal "grok-build-0.1", Chat.provider_model_id("x-ai/grok-build-0.1")
  end

  test "MODELS constant does not include thinking metadata for non-capable models" do
    non_thinking_models = Chat::MODELS.reject { |m| m.dig(:thinking, :supported) == true }

    # Verify we have non-thinking models
    assert non_thinking_models.any?, "Should have models without thinking"

    # Verify none have requires_direct_api flag
    non_thinking_models.each do |model|
      refute_equal true, model.dig(:thinking, :requires_direct_api),
                   "#{model[:model_id]} should not require direct API"
    end
  end

end
