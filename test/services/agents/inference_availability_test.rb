require "test_helper"

module Agents
  class InferenceAvailabilityTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.model_id = "openai/gpt-6-sol"
      @agent.provider_auth_modes = {}
      @agent.provider_connections = {}
      @agent.account.assign_attributes(use_system_ai_credentials: false)
      Account::AI_PROVIDERS.each_key { |provider| @agent.account.public_send("#{provider}_api_key=", nil) }
    end

    test "no credentials and unrelated provider keys cannot fund the selected model" do
      assert_not InferenceAvailability.available?(@agent)
      @agent.account.anthropic_api_key = "test-anthropic"
      assert_not InferenceAvailability.available?(@agent)
    end

    test "account direct key selects and funds the same sandbox route" do
      Account.stub(:system_ai_api_key, nil) do
        @agent.account.openai_api_key = "test-openai"
        assert_equal "openai", Sandbox.chaos_provider_for(@agent)
        assert InferenceAvailability.available?(@agent)
      end
    end

    test "openrouter key funds models without a direct route" do
      @agent.model_id = "deepseek/deepseek-v4.1-flash"
      @agent.account.openai_api_key = "test-openai"
      assert_not InferenceAvailability.available?(@agent)
      @agent.account.openrouter_api_key = "test-router"
      assert InferenceAvailability.available?(@agent)
    end

    test "system keys are usable only when account fallback is enabled" do
      Account.stub(:system_ai_api_key, "test-system") do
        assert_not InferenceAvailability.available?(@agent)
        assert_equal "openrouter", Sandbox.chaos_provider_for(@agent)
        @agent.account.use_system_ai_credentials = true
        assert_equal "openai", Sandbox.chaos_provider_for(@agent)
        assert InferenceAvailability.available?(@agent)
      end
    end

    test "placeholder keys do not count" do
      @agent.account.openrouter_api_key = "<missing>"
      @agent.account.openai_api_key = "<missing>"
      assert_not InferenceAvailability.available?(@agent)
    end

    test "only connected selected OAuth works and stale OAuth does not pretend to fall through" do
      @agent.provider_auth_modes = { openai: "oauth_account" }.stringify_keys
      assert_not InferenceAvailability.available?(@agent)
      @agent.provider_connections = { "openai" => { "status" => "connected" } }
      assert InferenceAvailability.available?(@agent)
      @agent.provider_connections = { "openai" => { "status" => "expired" } }
      @agent.account.openai_api_key = "test-openai"
      assert_not InferenceAvailability.available?(@agent)
    end

    test "OAuth for another model is not a credential for this model" do
      @agent.provider_auth_modes = { "anthropic" => "oauth_account" }
      @agent.provider_connections = { "anthropic" => { "status" => "connected" } }
      assert_not InferenceAvailability.available?(@agent)
    end

  end
end
