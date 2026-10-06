require "test_helper"

module Agents
  class SubagentCatalogTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.account.assign_attributes(use_system_ai_credentials: false)
      Account::AI_PROVIDERS.each_key { |provider| @agent.account.public_send("#{provider}_api_key=", nil) }
      @agent.account.save!
      @agent.provider_auth_modes = {}
    end

    test "an OpenRouter key gives openrouter options keyed by the Chat model id" do
      @agent.account.openrouter_api_key = "sk-or-test"

      catalog = SubagentCatalog.new(@agent)
      option = catalog.options.find { |candidate| candidate[:key] == "openrouter:deepseek/deepseek-v4-pro-0813" }

      assert option
      assert_equal "openrouter", option[:provider]
      assert_equal "deepseek/deepseek-v4-pro-0813", option[:model]
      assert_equal "DeepSeek V4 Pro 0813", option[:label]
      assert_equal "API key", option[:source]
    end

    test "an OpenAI key gives openai options keyed by provider_model_id only for models that have one" do
      @agent.account.openai_api_key = "sk-test-openai"

      catalog = SubagentCatalog.new(@agent)
      openai_options = catalog.options.select { |candidate| candidate[:provider] == "openai" }

      with_mapping = openai_options.find { |candidate| candidate[:label] == "GPT-5 Mini" }
      assert with_mapping
      assert_equal "gpt-5-mini", with_mapping[:model]
      assert_equal "openai:gpt-5-mini", with_mapping[:key]

      assert_not openai_options.any? { |candidate| candidate[:label] == "O4 Mini High" },
        "a model without provider_model_id must not be offered as an openai sub-agent option"
    end

    test "a resident running on a Claude subscription gets the Claude Code aliases" do
      @agent.model_id = "anthropic/claude-opus-5.5"
      @agent.provider_auth_modes = { "anthropic" => "oauth_account" }

      catalog = SubagentCatalog.new(@agent)
      anthropic_options = catalog.options.select { |candidate| candidate[:provider] == "anthropic" }

      expected_keys = SubagentCatalog::CLAUDE_CODE_MODELS.map { |model, _label| "anthropic:#{model}" }
      assert_equal expected_keys.sort, anthropic_options.map { |candidate| candidate[:key] }.sort
      assert anthropic_options.all? { |candidate| candidate[:source] == "Claude subscription" }
    end

    # At the pinned Chaos, a child on another provider rides that provider's
    # direct transport, so an OpenRouter parent cannot reach a Claude subscription.
    test "another provider's subscription is not offered across providers" do
      @agent.account.openrouter_api_key = "sk-or-test"
      @agent.provider_auth_modes = { "anthropic" => "oauth_account" }

      catalog = SubagentCatalog.new(@agent)

      assert_equal [ "openrouter" ], catalog.providers.map { |entry| entry[:provider] }
      assert_nil catalog.resolve("anthropic:sonnet")
    end

    test "across providers, an API key is offered in place of the subscription" do
      @agent.account.anthropic_api_key = "sk-ant-test"
      @agent.provider_auth_modes = { "anthropic" => "oauth_account" }

      anthropic = SubagentCatalog.new(@agent).providers.find { |entry| entry[:provider] == "anthropic" }

      assert_equal "API key", anthropic[:source]
    end

    test "no keys leaves providers empty with a reason" do
      catalog = SubagentCatalog.new(@agent)

      assert_empty catalog.providers
      assert_includes catalog.empty_reason, "Add an API key"
    end

    test "a house-funded resident gets no API-key providers" do
      @agent.account.openrouter_api_key = "sk-or-test"
      @agent.model_id = HouseInference::Offering::MODEL_ID

      catalog = SubagentCatalog.new(@agent)

      assert_empty catalog.providers
      assert_includes catalog.empty_reason, "house-funded inference"
    end

    test "resolve of a custom id on an available provider marks it custom" do
      @agent.account.openrouter_api_key = "sk-or-test"

      catalog = SubagentCatalog.new(@agent)
      resolved = catalog.resolve("openrouter:some/custom-model")

      assert resolved
      assert resolved[:custom]
      assert_equal "openrouter", resolved[:provider]
      assert_equal "some/custom-model", resolved[:model]
    end

    test "resolve returns nil when the provider has no credentials" do
      catalog = SubagentCatalog.new(@agent)

      assert_nil catalog.resolve("anthropic:claude-sonnet-5")
    end

  end
end
