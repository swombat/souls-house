require "test_helper"

class Agent::ModelSwitchingTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(model_id: "anthropic/claude-opus-5.5")
  end

  test "allowlist accepts a same-provider catalogue model and drops the default" do
    @agent.update!(switchable_model_ids: [ "anthropic/claude-fable-5.1", "anthropic/claude-opus-5.5", " anthropic/claude-fable-5.1 " ])

    assert_equal [ "anthropic/claude-fable-5.1" ], @agent.switchable_model_ids
    assert_equal [ "anthropic/claude-opus-5.5", "anthropic/claude-fable-5.1" ], @agent.model_choices.map { |c| c[:model_id] }
    assert @agent.model_switching_available?
  end

  test "allowlist refuses another provider family and unknown models" do
    @agent.switchable_model_ids = [ "openai/gpt-6-astra", "anthropic/not-a-model" ]

    assert_not @agent.valid?
    messages = @agent.errors[:switchable_model_ids].join(" ")
    assert_match(/different provider/, messages)
    assert_match(/not in the model catalogue/, messages)
  end

  test "changing the default does not block an unrelated save, but the stale entry is reported" do
    @agent.update!(switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    @agent.update!(model_id: "openai/gpt-6.1-sol")

    @agent.update!(name: "Renamed")
    assert_match(/different provider/, @agent.model_selection_problem("anthropic/claude-fable-5.1"))
    assert_equal [ "openai/gpt-6.1-sol" ], @agent.model_choices.map { |c| c[:model_id] }
  end

  test "changing the allowlist fires no model-change notice" do
    assert_no_difference "Notice.count" do
      @agent.update!(switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    end
  end

end
