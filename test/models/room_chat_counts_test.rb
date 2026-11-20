require "test_helper"

class RoomChatCountsTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @account = @lume.account
    @account.update!(show_room_chat_counts: true)
    @room = @account.rooms.create!(name: "Workshop")
    @empty = @account.rooms.create!(name: "Garage")
  end

  def chat(title, room: nil)
    @account.chats.create!(title: title, manual_responses: true, room: room, agents: [ @lume ])
  end

  test "the switch is off by default, and off sends nothing" do
    assert_not Account.new.show_room_chat_counts?
    @account.update!(show_room_chat_counts: false)
    chat("In Main")
    assert_nil RoomChatCounts.summary_for(@account)
    assert_nil RoomChatCounts.summary_for(nil)
  end

  test "each room counts the conversations its list shows, Main as its own key, All across them" do
    before = @account.chats.kept.listed.active.not_hidden_from_list.where(room_id: nil).count
    2.times { |i| chat("Workshop #{i}", room: @room) }
    chat("In Main")

    summary = RoomChatCounts.summary_for(@account)
    assert_equal 2, summary[:rooms][@room.to_param]
    assert_equal before + 1, summary[:rooms]["main"]
    assert_nil summary[:rooms][@empty.to_param], "an empty room has no key; the menus show 0"
    assert_equal before + 3, summary[:all]
  end

  test "archived, deleted and hidden conversations are left out" do
    kept = chat("Kept", room: @room)
    chat("Archived", room: @room).archive!
    chat("Deleted", room: @room).discard!
    hiding = @account.visual_tags.create!(label: "Parked", icon: "Check", colour: "rose", hides_from_list: true)
    chat("Hidden", room: @room).update!(visual_tag: hiding)

    assert_equal 1, RoomChatCounts.summary_for(@account)[:rooms][@room.to_param]
    assert kept.persisted?
  end

  test "another account's conversations never count, whoever is looking" do
    stranger = agents(:other_account_agent)
    other = stranger.account
    assert_not_equal @account.id, other.id
    other.update!(show_room_chat_counts: true)
    other_room = other.rooms.create!(name: "Theirs")
    other.chats.create!(title: "Theirs", manual_responses: true, room: other_room, agents: [ stranger ])

    mine = RoomChatCounts.summary_for(@account)
    assert_nil mine[:rooms][other_room.to_param]
    assert_equal @account.chats.kept.listed.active.not_hidden_from_list.count, mine[:all]
    assert_equal 1, RoomChatCounts.summary_for(other)[:rooms][other_room.to_param]
  end

  test "every room is counted in one query" do
    chat("A", room: @room)
    chat("B", room: @empty)
    chat("C")

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { RoomChatCounts.summary_for(@account) }
    assert_equal 1, queries.size, queries.join("\n")
  end

end
