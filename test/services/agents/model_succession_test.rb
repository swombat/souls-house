require "test_helper"

class Agents::ModelSuccessionTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.2" ])
    @chat = conversation
  end

  def conversation
    chat = @agent.account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ @agent.id ]
    chat.save!
    chat
  end

  def seat(chat = @chat) = ChatAgent.find_by!(chat: chat, agent: @agent)

  # A pin that has left the list can't be made through select_model!, which
  # refuses it; it is what a list edit leaves behind.
  def pin!(model_id, chat = @chat) = seat(chat).update_column(:model_id, model_id)

  def house_lines(chat = @chat) = chat.messages.where(role: "system").pluck(:content)

  test "successor_for walks the line forward to the first model the resident may select" do
    assert_equal "anthropic/claude-fable-5.2", Agents::ModelSuccession.successor_for(@agent, "anthropic/claude-fable-5")
    assert_equal "anthropic/claude-opus-5.5", Agents::ModelSuccession.successor_for(@agent, "anthropic/claude-opus-4.8"),
      "the resident's default counts as a model it may select"
    assert_nil Agents::ModelSuccession.successor_for(@agent, "anthropic/claude-sonnet-4.6"), "no newer Sonnet on the list"
    assert_nil Agents::ModelSuccession.successor_for(@agent, "google/gemini-4-carbon"), "unrecorded lineage never guesses"
  end

  test "a conversation pin off the list moves to its successor, once, with one house line" do
    pin!("anthropic/claude-fable-5.1")
    assert_not Agents::ModelSelection.for(@agent, chat: @chat).ok?

    move = Agents::ModelSuccession.repair!(@agent, chat: @chat)

    assert_equal "anthropic/claude-fable-5.2", move.to_model_id
    assert_equal "anthropic/claude-fable-5.2", seat.model_id
    selection = Agents::ModelSelection.for(@agent, chat: @chat)
    assert selection.ok?
    assert_equal "anthropic/claude-fable-5.2", selection.model_id
    assert_equal 1, house_lines.size
    assert_match(/moved from Claude Fable 5\.1 to Claude Fable 5\.2, because Claude Fable 5\.1 is no longer on/, house_lines.first)

    assert_nil Agents::ModelSuccession.repair!(@agent, chat: @chat), "a second wake finds nothing to move"
    assert_equal 1, house_lines.size
  end

  test "no successor on the list keeps the pin and the visible refusal" do
    @agent.update!(switchable_model_ids: [])
    pin!("anthropic/claude-fable-5.1")

    assert_nil Agents::ModelSuccession.repair!(@agent, chat: @chat)
    assert_equal "anthropic/claude-fable-5.1", seat.model_id, "the default is not a successor of Fable"
    assert Agents::ModelSelection.for(@agent, chat: @chat).off_list?
    assert_empty house_lines
  end

  test "a pin that is still on the list, or the default, is never touched" do
    pin!("anthropic/claude-fable-5.2")
    assert_nil Agents::ModelSuccession.repair!(@agent, chat: @chat)
    pin!(nil)
    assert_nil Agents::ModelSuccession.repair!(@agent, chat: @chat)
    assert_empty house_lines
  end

  test "a person's re-pick made after the pin was read wins" do
    pin!("anthropic/claude-fable-5.1")
    stale = seat
    ChatAgent.stub(:find_by, stale) do
      # The person picks the default between the read and the write.
      ChatAgent.where(id: stale.id).update_all(model_id: nil)
      assert_nil Agents::ModelSuccession.repair!(@agent, chat: @chat)
    end
    assert_nil seat.model_id
    assert_empty house_lines
  end

  test "only the resident who lost the model moves; the room default stays as set" do
    other = agents(:research_assistant).dup
    other.assign_attributes(name: "Second resident", model_id: "anthropic/claude-opus-5.5",
      switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
    other.save!(validate: false)
    room = @chat.room || rooms_for(@agent.account)
    RoomModelDefault.create!(account: @agent.account, room: room, agent: other, model_id: "anthropic/claude-fable-5.1")
    @chat.update_column(:room_id, room.id)
    ChatAgent.create!(chat: @chat, agent: other)
    assert_equal "anthropic/claude-fable-5.1", ChatAgent.find_by!(chat: @chat, agent: other).model_id
    pin!("anthropic/claude-fable-5.1")

    Agents::ModelSuccession.repair!(@agent, chat: @chat)
    assert_nil Agents::ModelSuccession.repair!(other, chat: @chat), "it is still on the other resident's list"

    assert_equal "anthropic/claude-fable-5.2", seat.model_id
    assert_equal "anthropic/claude-fable-5.1", ChatAgent.find_by!(chat: @chat, agent: other).model_id
    assert_equal "anthropic/claude-fable-5.1", RoomModelDefault.find_by!(room: room, agent: other).model_id
  end

  # The case that started it: Alanis's rhythms were pinned to GPT-6.1 Sol,
  # which left her list while GPT-6.2 Sol was on it.
  test "a rhythm pin moves at its first run and the rhythm itself carries the new model" do
    @agent.update!(model_id: "openai/gpt-6.2-astra", switchable_model_ids: [ "openai/gpt-6.2-sol" ])
    rhythms = Array.new(4) do |index|
      rhythm = Rhythm.create!(account: @agent.account, creator: users(:user_1), title: "Rhythm #{index}",
        opening: "Keep going.", agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC",
        next_run_at: 1.day.ago)
      rhythm.rhythm_agents.update_all(model_id: "openai/gpt-6.1-sol")
      rhythm
    end

    occurrence = rhythms.first.fire!(manual: true, request_key: SecureRandom.hex(8), requested_by_user: users(:user_1)).occurrence
    chat = occurrence.chat
    assert_equal "openai/gpt-6.1-sol", seat(chat).model_id, "the dispatch copied the stale pin"

    move = Agents::ModelSuccession.repair!(@agent, chat: chat)

    assert_equal rhythms.first, move.rhythm
    assert_equal "openai/gpt-6.2-sol", seat(chat).model_id
    assert_equal "openai/gpt-6.2-sol", rhythms.first.rhythm_agents.sole.model_id
    assert_match(/The rhythm "Rhythm 0" will use GPT-6\.2 Sol from now on too/, house_lines(chat).last)
    assert_equal [ "openai/gpt-6.1-sol" ] * 3, rhythms.drop(1).map { |rhythm| rhythm.rhythm_agents.sole.model_id },
      "each rhythm moves at its own run, in its own thread"
    assert_equal "openai/gpt-6.2-sol", rhythms.first.fire!(manual: true, request_key: SecureRandom.hex(8), requested_by_user: users(:user_1)).occurrence.chat.chat_agents.sole.model_id
  end

  test "a provider problem is not a reason to move" do
    @agent.update!(switchable_model_ids: [ "anthropic/claude-fable-5.1", "anthropic/claude-fable-5.2" ])
    pin!("anthropic/claude-fable-5.1")
    assert_nil Agents::ModelSuccession.repair!(@agent, chat: @chat)
    assert_equal "anthropic/claude-fable-5.1", seat.model_id
  end

  test "every recorded successor stays inside its provider family" do
    Agents::ModelSuccession::SUCCESSORS.each do |from, to|
      assert_equal Agent.model_family(from), Agent.model_family(to), "#{from} => #{to}"
    end
  end

  private

  def rooms_for(account)
    Room.create!(account: account, name: "Succession room")
  end

end
