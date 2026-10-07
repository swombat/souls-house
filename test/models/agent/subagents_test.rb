require "test_helper"

class Agent::SubagentsTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.account.assign_attributes(use_system_ai_credentials: false)
    Account::AI_PROVIDERS.each_key { |provider| @agent.account.public_send("#{provider}_api_key=", nil) }
    @agent.account.save!
    @agent.provider_auth_modes = {}
  end

  test "subagents are disabled with an empty model list by default" do
    agent = Agent.new
    assert_not agent.subagents_enabled?
    assert_equal [], agent.subagent_models
  end

  test "normalisation strips whitespace, drops blanks, and dedupes" do
    @agent.subagent_models = [
      " openrouter:deepseek/deepseek-v4-pro-0813 ",
      "",
      "   ",
      "openrouter:deepseek/deepseek-v4-pro-0813",
      nil
    ]

    assert @agent.valid?
    assert_equal [ "openrouter:deepseek/deepseek-v4-pro-0813" ], @agent.subagent_models
  end

  test "invalid keys are rejected" do
    @agent.subagent_models = [ "openrouter:deepseek/deepseek-v4-pro-0813", "NotLowercase:model", "no-colon-here", "openrouter:" ]

    assert_not @agent.valid?
    assert @agent.errors[:subagent_models].any? { |message| message.include?("invalid entries") }
  end

  test "more than the maximum number of models is rejected" do
    @agent.subagent_models = (1..Agent::Subagents::MAX_SUBAGENT_MODELS + 1).map { |n| "openrouter:model-#{n}" }

    assert_not @agent.valid?
    assert_includes @agent.errors[:subagent_models], "can list at most #{Agent::Subagents::MAX_SUBAGENT_MODELS} models"
  end

  test "exactly the maximum number of well-formed models is allowed" do
    @agent.subagent_models = (1..Agent::Subagents::MAX_SUBAGENT_MODELS).map { |n| "openrouter:model-#{n}" }

    assert @agent.valid?
  end

  test "available_subagent_models is empty when disabled regardless of configured credentials" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.subagents_enabled = false
    @agent.subagent_models = [ "openrouter:deepseek/deepseek-v4-pro-0813" ]

    assert_empty @agent.available_subagent_models
  end

  test "available_subagent_models resolves catalogue entries and custom entries when enabled" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.update!(
      subagents_enabled: true,
      subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813", "openrouter:some-custom-model" ]
    )

    resolved = @agent.available_subagent_models
    assert_equal 2, resolved.size

    catalogue_entry = resolved.find { |entry| entry[:key] == "openrouter:deepseek/deepseek-v4-pro-0813" }
    assert catalogue_entry
    assert_equal "DeepSeek V4 Pro 0813", catalogue_entry[:label]
    assert_equal "deepseek/deepseek-v4-pro-0813", catalogue_entry[:model]
    assert_not catalogue_entry[:custom]

    custom_entry = resolved.find { |entry| entry[:key] == "openrouter:some-custom-model" }
    assert custom_entry
    assert custom_entry[:custom]
    assert_equal "some-custom-model", custom_entry[:model]
  end

  test "available_subagent_models drops keys whose provider has no credentials" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.update!(
      subagents_enabled: true,
      subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813", "anthropic:claude-opus-5" ]
    )

    assert_equal [ "openrouter:deepseek/deepseek-v4-pro-0813" ], @agent.available_subagent_models.map { |entry| entry[:key] }
  end

end
