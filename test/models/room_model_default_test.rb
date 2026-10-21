require "test_helper"

# A room can say which model a resident starts on in its new conversations.
class RoomModelDefaultTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @account = @agent.account
    @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    @build = @account.rooms.create!(name: "Build")
  end

  def new_chat(room: nil, agents: [ @agent, @other ])
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true, room: room)
    chat.agent_ids = agents.map(&:id)
    chat.save!
    chat
  end

  def seat(chat, agent) = ChatAgent.find_by!(chat: chat, agent: agent)

  test "a new conversation in a room seats the resident on the room's model" do
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")

    chat = new_chat(room: @build)
    assert_equal "anthropic/claude-fable-5.1", seat(chat, @agent).model_id
    assert_nil seat(chat, @other).model_id
    assert_equal "anthropic/claude-fable-5.1", Agents::ModelSelection.for(@agent, chat: chat).model_id

    assert_nil seat(new_chat, @agent).model_id, "Main has its own default, unset here"
  end

  test "Main has a default of its own" do
    RoomModelDefault.set!(account: @account, room: nil, agent: @agent, model_id: "anthropic/claude-fable-5.1")

    assert_equal "anthropic/claude-fable-5.1", seat(new_chat, @agent).model_id
    assert_nil seat(new_chat(room: @build), @agent).model_id
  end

  test "a resident joining later starts on the room's model too" do
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    chat = new_chat(room: @build, agents: [ @other ])

    chat.agents << @agent
    assert_equal "anthropic/claude-fable-5.1", seat(chat, @agent).model_id
  end

  test "changing the room's default leaves existing conversations alone" do
    chat = new_chat(room: @build)
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")

    assert_nil seat(chat, @agent).model_id
  end

  test "choosing the resident's own default clears the room's" do
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    assert_nil RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-opus-5.5")
    assert_equal 0, RoomModelDefault.count
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "default")
    assert_equal 0, RoomModelDefault.count
  end

  test "only a model on the resident's list can be a room default" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      RoomModelDefault.set!(account: @account, room: @build, agent: @other, model_id: "anthropic/claude-fable-5.1")
    end
    assert_match "list of models for conversations", error.message
  end

  test "a default that stopped being on the list is skipped, and reported" do
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    @agent.update!(switchable_model_ids: [])

    assert_nil seat(new_chat(room: @build), @agent).model_id
    assert_match "list of models", RoomModelDefault.sole.as_json["problem"]
  end

  test "one default per resident per room, Main included" do
    RoomModelDefault.set!(account: @account, room: nil, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    duplicate = RoomModelDefault.new(account: @account, room: nil, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "a room or resident from another account is refused" do
    stranger = agents(:other_account_agent)
    record = RoomModelDefault.new(account: @account, room: nil, agent: stranger, model_id: "anthropic/claude-fable-5.1")
    assert_not record.valid?
    assert record.errors.key?(:agent)
  end

  test "removing the room removes its defaults" do
    RoomModelDefault.set!(account: @account, room: @build, agent: @agent, model_id: "anthropic/claude-fable-5.1")
    @build.destroy!
    assert_equal 0, RoomModelDefault.count
  end

end
