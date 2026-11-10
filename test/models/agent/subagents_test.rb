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
    @agent.account.granted_plan = "colleagues"
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
    @agent.account.granted_plan = "colleagues"
    @agent.update!(
      subagents_enabled: true,
      subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813", "anthropic:claude-opus-5" ]
    )

    assert_equal [ "openrouter:deepseek/deepseek-v4-pro-0813" ], @agent.available_subagent_models.map { |entry| entry[:key] }
  end

  # Sub-agents come with the account's Colleagues plan (2026-11-10), for a
  # resident whose own hosting is in force or that is on the house.
  test "sub-agents come with a Colleagues account, not the resident's size" do
    assert_not @agent.subagents_available?, "Companions: none, even on the house"
    @agent.account.update!(granted_plan: "partners")
    assert_not @agent.reload.subagents_available?, "Partners: none"

    @agent.account.update!(granted_plan: "colleagues")
    assert @agent.reload.subagents_available?, "Colleagues: a resident on the house has them"

    entitlement = ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "complimentary",
      state: "complimentary", complimentary_granted_at: Time.current)
    assert @agent.subagents_available?

    %w[conversation life work].each do |tier|
      entitlement.update_columns(source: "stripe", state: "active", tier: tier)
      assert @agent.subagents_available?, "any size in a Colleagues account: #{tier}"
    end
  end

  test "in a Colleagues account the resident's own plan must be in force" do
    @agent.account.update!(granted_plan: "colleagues")
    entitlement = ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe",
      state: "active", tier: "conversation")
    assert @agent.subagents_available?

    entitlement.update!(state: "grace")
    assert @agent.subagents_available?

    entitlement.update_columns(state: "held")
    assert_not @agent.subagents_available?

    entitlement.update_columns(state: "pending")
    assert_not @agent.subagents_available?
  end

  test "a paid Colleagues subscription grants them; ending it takes them away" do
    subscription = AccountSubscription.create!(account: @agent.account, stripe_subscription_id: "sub_acct",
      plan: "colleagues", stripe_status: "active")
    assert @agent.subagents_available?

    subscription.update!(stripe_status: "canceled")
    assert_not @agent.reload.subagents_available?
  end

  test "a lower plan cannot switch sub-agents on, and a switch left on grants nothing" do
    @agent.account.update!(openrouter_api_key: "sk-or-test", granted_plan: "colleagues")
    @agent.update!(subagents_enabled: true, subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813" ])
    assert_equal 1, @agent.available_subagent_models.size

    @agent.account.update!(granted_plan: "partners")
    @agent.reload
    assert_not @agent.subagents_permitted?
    assert_equal [], @agent.available_subagent_models
    assert @agent.update(name: "Renamed"), "an unrelated save still works with the switch left on"

    @agent.update!(subagents_enabled: false)
    @agent.subagents_enabled = true
    assert_not @agent.valid?
    assert_includes @agent.errors[:subagents_enabled], "Sub-agents come with the Colleagues plan"
  end

  test "a paid birth waiting for its billing link is not taken for a resident on the house" do
    @agent.account.update!(granted_plan: "colleagues")
    assert @agent.subagents_available?

    ResidentBirthOrder.create!(account: @agent.account, creator: users(:user_1), tier: "life", state: "born",
      agent: @agent)
    assert_not @agent.subagents_available?, "no entitlement yet, but this resident was paid for"

    ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe", state: "active",
      tier: "work")
    assert @agent.subagents_available?, "once linked, the plan decides"
  end

end
