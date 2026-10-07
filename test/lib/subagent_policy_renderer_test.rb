require "test_helper"

class SubagentPolicyRendererTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.account.assign_attributes(use_system_ai_credentials: false)
    Account::AI_PROVIDERS.each_key { |provider| @agent.account.public_send("#{provider}_api_key=", nil) }
    @agent.account.save!
    @agent.provider_auth_modes = {}
  end

  test "section is nil for a resident whose policy was never set" do
    @agent.subagents_enabled = false
    @agent.subagents_policy_changed_at = nil

    assert_nil SubagentPolicyRenderer.section_for(@agent)
  end

  test "switching sub-agents off sends an explicit revocation that supersedes the earlier permission" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.update!(subagents_enabled: true, subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813" ])
    assert_includes SubagentPolicyRenderer.section_for(@agent), "standing permission"

    @agent.update!(subagents_enabled: false)
    section = SubagentPolicyRenderer.section_for(@agent)

    assert_includes section, "## Sub-agents: no standing permission"
    assert_includes section, "replaces any earlier sub-agent policy"
    refute_includes section, "deepseek"
  end

  test "changing the allowlist changes the next trigger's list" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.update!(subagents_enabled: true, subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813" ])
    @agent.update!(subagent_models: [ "openrouter:z-ai/glm-5.2" ])

    section = SubagentPolicyRenderer.section_for(@agent)

    assert_includes section, "`model: z-ai/glm-5.2`"
    refute_includes section, "deepseek"
  end

  test "section states standing permission and lists each allowed model when enabled" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.account.openai_api_key = "sk-openai-test"
    @agent.subagents_enabled = true
    @agent.subagent_models = [ "openrouter:deepseek/deepseek-v4-pro-0813", "openai:gpt-5-mini" ]

    section = SubagentPolicyRenderer.section_for(@agent)

    assert_includes section, "standing permission"
    assert_includes section, "Always pass `model`"
    # research_assistant's own model (openrouter/auto) resolves to the openrouter provider,
    # so its own-provider entry omits model_provider.
    assert_includes section, "DeepSeek V4 Pro 0813: `model: deepseek/deepseek-v4-pro-0813`, omit `model_provider` (your own provider)"
    assert_includes section, "GPT-5 Mini: `model: gpt-5-mini`, `model_provider: openai`"
  end

  test "an empty allowlist grants no fallback to the resident's own model" do
    @agent.subagents_enabled = true
    @agent.subagent_models = []

    section = SubagentPolicyRenderer.section_for(@agent)

    assert_includes section, "## Sub-agents: no allowed models"
    assert_includes section, "do not spawn sub-agents unless someone in the conversation explicitly asks"
    refute_includes section, "standing permission to use"
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
