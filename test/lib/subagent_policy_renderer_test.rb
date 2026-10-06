require "test_helper"

class SubagentPolicyRendererTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.account.assign_attributes(use_system_ai_credentials: false)
    Account::AI_PROVIDERS.each_key { |provider| @agent.account.public_send("#{provider}_api_key=", nil) }
    @agent.account.save!
    @agent.provider_auth_modes = {}
  end

  test "section is nil when subagents are disabled" do
    @agent.subagents_enabled = false

    assert_nil SubagentPolicyRenderer.section_for(@agent)
  end

  test "section states standing permission and lists each allowed model when enabled" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.provider_auth_modes = { "anthropic" => "oauth_account" }
    @agent.subagents_enabled = true
    @agent.subagent_models = [ "openrouter:deepseek/deepseek-v4-pro-0813", "anthropic:sonnet" ]

    section = SubagentPolicyRenderer.section_for(@agent)

    assert_includes section, "standing permission"
    # research_assistant's own model (openrouter/auto) resolves to the openrouter provider,
    # so its own-provider entry omits model_provider.
    assert_includes section, "DeepSeek V4 Pro 0813: `model: deepseek/deepseek-v4-pro-0813`, omit `model_provider` (your own provider)"
    assert_includes section, "Claude Sonnet (latest): `model: sonnet`, `model_provider: anthropic`"
  end

  test "an empty allowlist tells the resident to omit model and model_provider" do
    @agent.subagents_enabled = true
    @agent.subagent_models = []

    section = SubagentPolicyRenderer.section_for(@agent)

    assert_includes section, "No other models are allowed for sub-agents. Spawn them on your own model: omit `model` and `model_provider`."
  end

  test "keys whose provider lost credentials are omitted from the rendered list" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.subagents_enabled = true
    @agent.subagent_models = [ "openrouter:deepseek/deepseek-v4-pro-0813", "anthropic:sonnet" ]

    section = SubagentPolicyRenderer.section_for(@agent)

    assert_includes section, "DeepSeek V4 Pro 0813"
    refute_includes section, "Claude Sonnet"
    refute_includes section, "model: sonnet"
  end

end
