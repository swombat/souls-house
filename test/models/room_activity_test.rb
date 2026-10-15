require "test_helper"
require "action_cable/test_helper"

class RoomActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @lume.update!(colour: "orange")
    @mira.update!(colour: "violet")
    @account = @lume.account
    @room = @account.rooms.create!(name: "Dev")
    @main_chat = @account.chats.create!(title: "In Main", manual_responses: true, agents: [ @lume, @mira ])
    @dev_chat = @account.chats.create!(title: "In Dev", manual_responses: true, room: @room, agents: [ @lume, @mira ])
  end

  test "nothing working is an empty summary" do
    assert_equal({ rooms: {}, all: [] }, RoomActivity.summary_for(@account))
    assert_equal({ rooms: {}, all: [] }, RoomActivity.summary_for(nil))
  end

  test "rooms are summarised account-wide, newest start first, falling back when the newest finishes" do
    lume = start_run(@lume, @dev_chat, started_at: 2.minutes.ago)
    mira = start_run(@mira, @dev_chat, started_at: 1.minute.ago)

    assert_equal [ "violet", "orange" ], colours(@room.to_param)
    assert_equal [ "Code Reviewer", "Research Assistant" ], names(@room.to_param)
    assert_nil summary[:rooms]["main"]

    mira.update!(execution_state: "completed", finished_at: Time.current)
    assert_equal [ "orange" ], colours(@room.to_param)

    lume.update!(execution_state: "failed", finished_at: Time.current)
    assert_nil summary[:rooms][@room.to_param]
  end

  test "a resident with several runs in a room is listed once, by their newest start" do
    start_run(@lume, @dev_chat, started_at: 5.minutes.ago)
    start_run(@mira, @dev_chat, started_at: 3.minutes.ago)
    other = @account.chats.create!(title: "Also Dev", manual_responses: true, room: @room, agents: [ @lume ])
    start_run(@lume, other, started_at: 1.minute.ago)

    assert_equal [ "Research Assistant", "Code Reviewer" ], names(@room.to_param)
  end

  test "Main is its own key and All chats spans every room" do
    start_run(@lume, @main_chat, started_at: 1.minute.ago)
    start_run(@mira, @dev_chat, started_at: 2.minutes.ago)

    assert_equal [ "Research Assistant" ], names("main")
    assert_equal [ "Code Reviewer" ], names(@room.to_param)
    assert_equal [ "Research Assistant", "Code Reviewer" ], summary[:all].map { |agent| agent[:name] }
    assert_equal @lume.to_param, summary[:all].first[:id]
  end

  test "discarded conversations and other accounts do not spin" do
    start_run(@lume, @dev_chat)
    @dev_chat.discard!
    other_account_agent = Agent.where.not(account_id: @account.id).first
    if other_account_agent
      chat = other_account_agent.account.chats.create!(title: "Elsewhere", manual_responses: true, agents: [ other_account_agent ])
      start_run(other_account_agent, chat)
    end

    assert_equal({ rooms: {}, all: [] }, summary)
  end

  test "lifecycle transitions and room moves refresh the account's room activity stream" do
    channel = "RoomActivity:#{@account.to_param}"
    interaction = nil
    assert_broadcast_on(channel, action: "refresh") { interaction = start_run(@lume, @main_chat) }
    assert_no_broadcasts(channel) { interaction.update!(stdout: "diagnostic") }
    assert_broadcast_on(channel, action: "refresh") { @main_chat.update!(room: @room) }
    assert_broadcast_on(channel, action: "refresh") do
      interaction.update!(execution_state: "completed", finished_at: Time.current)
    end
    assert_no_broadcasts(channel) { @main_chat.update!(room: nil) }
  end

  private

  def summary
    RoomActivity.summary_for(@account)
  end

  def names(key)
    summary[:rooms].fetch(key).map { |agent| agent[:name] }
  end

  def colours(key)
    summary[:rooms].fetch(key).map { |agent| agent[:colour] }
  end

  def start_run(agent, chat, started_at: Time.current)
    AgentRuntimeInteraction.create!(
      agent: agent, chat: chat, trigger_kind: "conversation",
      started_at: started_at, run_id: SecureRandom.uuid, execution_state: "running"
    )
  end

end
