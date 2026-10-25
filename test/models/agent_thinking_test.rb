require "test_helper"

class AgentThinkingTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @agent = @account.agents.create!(
      name: "Test Thinking Agent",
      model_id: "anthropic/claude-opus-4.5",
      thinking_enabled: false,
      thinking_budget: nil
    )
  end

  test "uses_thinking? returns true when enabled and model supports it" do
    @agent.model_id = "anthropic/claude-opus-4.5"
    @agent.thinking_enabled = true
    assert @agent.uses_thinking?
  end

  test "uses_thinking? returns true for Claude Sonnet 4.5 with thinking enabled" do
    @agent.model_id = "anthropic/claude-sonnet-4.5"
    @agent.thinking_enabled = true
    assert @agent.uses_thinking?
  end

  test "uses_thinking? returns true for Claude 4 models with thinking enabled" do
    @agent.model_id = "anthropic/claude-opus-4.8"
    @agent.thinking_enabled = true
    assert @agent.uses_thinking?

    @agent.model_id = "anthropic/claude-opus-4.7"
    assert @agent.uses_thinking?
  end

  test "uses_thinking? returns true for OpenAI GPT-5 models with thinking enabled" do
    @agent.model_id = "openai/gpt-5.2"
    @agent.thinking_enabled = true
    assert @agent.uses_thinking?

    @agent.model_id = "openai/gpt-5.1"
    assert @agent.uses_thinking?

    @agent.model_id = "openai/gpt-5"
    assert @agent.uses_thinking?
  end

  test "uses_thinking? returns true for Google Gemini 3 Pro with thinking enabled" do
    @agent.model_id = "google/gemini-3.1-pro-preview"
    @agent.thinking_enabled = true
    assert @agent.uses_thinking?
  end

  test "uses_thinking? returns false when model does not support thinking" do
    @agent.model_id = "openai/gpt-4o-mini"
    @agent.thinking_enabled = true
    refute @agent.uses_thinking?
  end

  test "uses_thinking? returns false for GPT-4 models even when enabled" do
    @agent.model_id = "openai/gpt-4o"
    @agent.thinking_enabled = true
    refute @agent.uses_thinking?

    @agent.model_id = "openai/gpt-4o-mini"
    refute @agent.uses_thinking?
  end

  test "uses_thinking? returns false when thinking is disabled" do
    @agent.model_id = "anthropic/claude-opus-4.5"
    @agent.thinking_enabled = false
    refute @agent.uses_thinking?
  end

  test "uses_thinking? returns false when thinking_enabled is nil" do
    @agent.model_id = "anthropic/claude-opus-4.5"
    @agent.thinking_enabled = nil
    refute @agent.uses_thinking?
  end

  test "validates thinking_budget minimum" do
    @agent.thinking_budget = 999
    refute @agent.valid?
    assert @agent.errors[:thinking_budget].any?
    assert_includes @agent.errors[:thinking_budget].first, "greater than or equal to 1000"
  end

  test "validates thinking_budget minimum edge case" do
    @agent.thinking_budget = 500
    refute @agent.valid?
    assert @agent.errors[:thinking_budget].any?
  end

  test "validates thinking_budget maximum" do
    @agent.thinking_budget = 50001
    refute @agent.valid?
    assert @agent.errors[:thinking_budget].any?
    assert_includes @agent.errors[:thinking_budget].first, "less than or equal to 50000"
  end

  test "validates thinking_budget maximum edge case" do
    @agent.thinking_budget = 100000
    refute @agent.valid?
    assert @agent.errors[:thinking_budget].any?
  end

  test "allows valid thinking_budget at minimum" do
    @agent.thinking_budget = 1000
    @agent.valid?
    refute @agent.errors[:thinking_budget].any?
  end

  test "allows valid thinking_budget at maximum" do
    @agent.thinking_budget = 50000
    @agent.valid?
    refute @agent.errors[:thinking_budget].any?
  end

  test "allows valid thinking_budget in middle range" do
    @agent.thinking_budget = 10000
    @agent.valid?
    refute @agent.errors[:thinking_budget].any?

    @agent.thinking_budget = 25000
    @agent.valid?
    refute @agent.errors[:thinking_budget].any?
  end

  test "allows nil thinking_budget" do
    @agent.thinking_budget = nil
    @agent.valid?
    refute @agent.errors[:thinking_budget].any?
  end

  test "thinking_enabled defaults to false" do
    new_agent = @account.agents.create!(
      name: "Default Agent",
      model_id: "openai/gpt-4o"
    )
    assert_equal false, new_agent.thinking_enabled
  end

  test "thinking_budget can be set on create" do
    new_agent = @account.agents.create!(
      name: "Budget Agent",
      model_id: "anthropic/claude-opus-4.5",
      thinking_enabled: true,
      thinking_budget: 15000
    )
    assert_equal 15000, new_agent.thinking_budget
  end

  test "thinking_budget can be updated" do
    @agent.update!(thinking_budget: 20000)
    assert_equal 20000, @agent.reload.thinking_budget
  end

  test "json_attributes includes thinking_enabled" do
    @agent.thinking_enabled = true
    json = @agent.as_json
    assert json.key?("thinking_enabled")
    assert_equal true, json["thinking_enabled"]
  end

  test "json_attributes includes thinking_budget" do
    @agent.thinking_budget = 12000
    json = @agent.as_json
    assert json.key?("thinking_budget")
    assert_equal 12000, json["thinking_budget"]
  end

  test "json_attributes includes nil thinking_budget" do
    @agent.thinking_budget = nil
    json = @agent.as_json
    assert json.key?("thinking_budget")
    assert_nil json["thinking_budget"]
  end

  test "can create agent with all thinking settings" do
    new_agent = @account.agents.create!(
      name: "Full Thinking Agent",
      model_id: "anthropic/claude-opus-4.5",
      thinking_enabled: true,
      thinking_budget: 30000,
      system_prompt: "You are a thoughtful assistant."
    )

    assert new_agent.persisted?
    assert new_agent.thinking_enabled
    assert_equal 30000, new_agent.thinking_budget
    assert new_agent.uses_thinking?
  end

  test "can disable thinking on existing agent" do
    @agent.update!(thinking_enabled: true, model_id: "anthropic/claude-opus-4.5")
    assert @agent.uses_thinking?

    @agent.update!(thinking_enabled: false)
    refute @agent.reload.uses_thinking?
  end

  test "changing model from thinking to non-thinking disables uses_thinking?" do
    @agent.update!(
      thinking_enabled: true,
      model_id: "anthropic/claude-opus-4.5"
    )
    assert @agent.uses_thinking?

    @agent.update!(model_id: "openai/gpt-4o")
    refute @agent.reload.uses_thinking?
    # Note: thinking_enabled is still true, but model doesn't support it
    assert @agent.thinking_enabled
  end

  test "changing model from non-thinking to thinking enables uses_thinking?" do
    @agent.update!(
      thinking_enabled: true,
      model_id: "openai/gpt-4o"
    )
    refute @agent.uses_thinking?

    @agent.update!(model_id: "anthropic/claude-opus-4.5")
    assert @agent.reload.uses_thinking?
  end

end
