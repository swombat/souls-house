require "test_helper"

class Agents::ModelSelectionTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(model_id: "anthropic/claude-opus-5.5", reasoning_effort: "high",
      switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    @room_a = room
    @room_b = room
  end

  def room
    chat = @agent.account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ @agent.id ]
    chat.save!
    chat
  end

  def seat(chat) = ChatAgent.find_by!(chat: chat, agent: @agent)

  test "no selection runs the default with the resident's own effort" do
    selection = Agents::ModelSelection.for(@agent, chat: @room_a)

    assert selection.ok?
    assert_equal "anthropic/claude-opus-5.5", selection.model_id
    assert_not selection.selected_by_conversation
    assert_equal "high", selection.reasoning_effort
    assert_equal Agents::Sandbox.chaos_model_for(@agent), selection.model
  end

  test "a selection applies to its own room only" do
    seat(@room_a).select_model!("anthropic/claude-fable-5.1", by: users(:user_1))

    assert_equal "anthropic/claude-fable-5.1", Agents::ModelSelection.for(@agent, chat: @room_a).model_id
    assert_equal "anthropic/claude-opus-5.5", Agents::ModelSelection.for(@agent, chat: @room_b).model_id
    assert_equal "anthropic/claude-opus-5.5", Agents::ModelSelection.for(@agent).model_id
  end

  test "the prompt section names the running model, the default and how to switch" do
    seat(@room_a).select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    text = Agents::ModelSelection.for(@agent, chat: @room_a).prompt_section

    assert_includes text, "You are running on Claude Fable 5.1"
    assert_includes text, "your default model is Claude Opus 5.5"
    assert_includes text, "you cannot change it yourself"
    assert_includes text, "keeps your Chaos session"

    @agent.update!(resident_may_switch_model: true)
    assert_includes Agents::ModelSelection.for(@agent, chat: @room_a).prompt_section, "soulshouse-model #{@room_a.to_param}"
  end

  test "no prompt section when the resident has nothing to switch between" do
    @agent.update!(switchable_model_ids: [])
    assert_nil Agents::ModelSelection.for(@agent, chat: @room_a).prompt_section
  end

  test "a selection that stopped being allowed is a problem, not the default" do
    seat(@room_a).select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    @agent.update!(switchable_model_ids: [])

    selection = Agents::ModelSelection.for(@agent, chat: @room_a)
    assert_not selection.ok?
    assert_equal "anthropic/claude-fable-5.1", selection.model_id
    assert_nil selection.model
    assert_match(/not on .* list/, selection.as_json[:problem])
  end

  test "select_model! records a platform line and is idempotent" do
    room_seat = seat(@room_a)

    assert_difference -> { @room_a.messages.where(role: "system").count }, 1 do
      assert room_seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
      assert_not room_seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    end
    line = @room_a.messages.where(role: "system").last
    assert_match(/will run on Claude Fable 5.1 .* from its next turn/, line.content)
    assert_equal "souls.house", line.author_name

    room_seat.select_model!("default", by: @agent)
    assert_nil room_seat.reload.model_id
    assert_match(/will run on its default, Claude Opus 5.5, in this conversation.*instead of Claude Fable 5.1\. Changed by Research Assistant \(the resident\)/, @room_a.messages.where(role: "system").last.content)
  end

  test "select_model! refuses a model off the list" do
    assert_raises(ChatAgent::ModelNotAllowed) do
      seat(@room_a).select_model!("anthropic/claude-haiku-5.5", by: users(:user_1))
    end
    assert_nil seat(@room_a).reload.model_id
  end

end
