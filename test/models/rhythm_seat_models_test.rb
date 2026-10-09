require "test_helper"

# A rhythm can say which model each resident runs on in the conversations it
# opens; the first turn of an occurrence must already run on it.
class RhythmSeatModelsTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @account = @agent.account
    @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    @now = Time.utc(2026, 10, 3, 10)
    @rhythm = Rhythm.create!(
      account: @account, creator: @user, title: "What to build", opening: "What should be built today?",
      agents: [ @agent, @other ], cadence: "daily", time_of_day: "09:00", timezone: "UTC",
      next_run_at: @now - 1.day
    )
  end

  def seat_for(chat, agent) = ChatAgent.find_by!(chat: chat, agent: agent)

  test "an occurrence opens with each resident's rhythm model already on its seat" do
    @rhythm.resident_models = { @agent.id => "anthropic/claude-fable-5.1" }
    @rhythm.save!
    assert_equal "anthropic/claude-fable-5.1", @rhythm.rhythm_agents.find_by!(agent: @agent).model_id

    chat = @rhythm.fire!(now: @now).occurrence.chat
    assert_equal "anthropic/claude-fable-5.1", seat_for(chat, @agent).model_id
    assert_nil seat_for(chat, @other).model_id
    selection = Agents::ModelSelection.for(@agent, chat: chat)
    assert_equal "anthropic/claude-fable-5.1", selection.model_id
    assert selection.selected_by_conversation
  end

  test "no rhythm model leaves the seat following the default" do
    chat = @rhythm.fire!(now: @now).occurrence.chat
    assert_nil seat_for(chat, @agent).model_id
    assert_equal "anthropic/claude-opus-5.5", Agents::ModelSelection.for(@agent, chat: chat).model_id
  end

  test "a model off the resident's list is a validation error and changes nothing" do
    @rhythm.resident_models = { @agent.id => "openai/gpt-6.1-sol" }
    assert_not @rhythm.save
    assert_match(/list of models/, @rhythm.errors[:resident_models].to_sentence)
    assert_nil @rhythm.rhythm_agents.find_by!(agent: @agent).reload.model_id
  end

  test "a model can only be set for a selected resident" do
    outsider = agents(:code_reviewer)
    @rhythm.update!(resident_ids: [ @agent.id ])
    @rhythm.resident_models = { outsider.id => "default" }
    assert_not @rhythm.save
    assert_match(/selected/, @rhythm.errors[:resident_models].to_sentence)
  end

  test "default and blank clear a selection, and omitted residents keep theirs" do
    @rhythm.update!(resident_models: { @agent.id => "anthropic/claude-fable-5.1" })
    @rhythm.update!(resident_models: { @other.id => "default" })
    assert_equal "anthropic/claude-fable-5.1", @rhythm.rhythm_agents.find_by!(agent: @agent).model_id
    @rhythm.update!(resident_models: { @agent.id => "" })
    assert_nil @rhythm.rhythm_agents.find_by!(agent: @agent).model_id
  end

  test "a rejected form edit rolls back its models with the rest" do
    assert_not @rhythm.update_from_form(title: "", resident_models: { @agent.id => "anthropic/claude-fable-5.1" })
    assert_nil @rhythm.rhythm_agents.find_by!(agent: @agent).reload.model_id
  end

  test "a new rhythm can be created with its models in one save" do
    rhythm = Rhythm.new(account: @account, creator: @user, title: "New", opening: "Hello",
      cadence: "daily", time_of_day: "09:00", timezone: "UTC")
    rhythm.assign_attributes(resident_ids: [ @agent.id ], resident_models: { @agent.id => "anthropic/claude-fable-5.1" })
    assert rhythm.save_from_form
    assert_equal({ @agent.id => "anthropic/claude-fable-5.1" }, rhythm.resident_models)
  end

  test "join can set or clear the joining resident's model" do
    @rhythm.join!(agent: @agent, model_id: "anthropic/claude-fable-5.1")
    assert_equal "anthropic/claude-fable-5.1", @rhythm.rhythm_agents.find_by!(agent: @agent).model_id
    @rhythm.join!(agent: @agent)
    assert_equal "anthropic/claude-fable-5.1", @rhythm.rhythm_agents.find_by!(agent: @agent).model_id
    @rhythm.join!(agent: @agent, model_id: "default")
    assert_nil @rhythm.rhythm_agents.find_by!(agent: @agent).model_id
    assert_raises(ActiveRecord::RecordInvalid) { @rhythm.join!(agent: @agent, model_id: "openai/gpt-6.1-sol") }
  end

  test "a selection that later leaves the allowlist is reported, not silently replaced" do
    @rhythm.update!(resident_models: { @agent.id => "anthropic/claude-fable-5.1" })
    @agent.update!(switchable_model_ids: [])
    chat = @rhythm.fire!(now: @now).occurrence.chat
    selection = Agents::ModelSelection.for(@agent, chat: chat)
    assert_equal "anthropic/claude-fable-5.1", selection.model_id
    assert_not selection.ok?
  end

end
