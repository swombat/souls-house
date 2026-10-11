require "test_helper"

class RoomTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
  end

  test "name must be present, bounded, and not a case-insensitive match for Main" do
    room = @account.rooms.new(name: "   ")
    assert_not room.valid?
    assert room.errors[:name].any?

    room.name = "x" * 41
    assert_not room.valid?
    assert room.errors[:name].any?

    room.name = "x" * 40
    assert room.valid?

    [ "Main", "main", "MAIN", "  main  " ].each do |value|
      room.name = value
      assert_not room.valid?, "#{value.inspect} should be refused as the reserved Main name"
      assert room.errors[:name].any?
    end
  end

  test "name uniqueness is case-insensitive and scoped to the account" do
    @account.rooms.create!(name: "Life")

    duplicate = @account.rooms.new(name: "life")
    assert_not duplicate.valid?
    assert duplicate.errors[:name].any?

    duplicate.name = "  LIFE  "
    assert_not duplicate.valid?

    # A different account may use the same name.
    assert accounts(:other).rooms.create!(name: "Life").persisted?
  end

  test "name is stripped before validation and save" do
    room = @account.rooms.create!(name: "  Spaced out  ")
    assert_equal "Spaced out", room.name
  end

  test "position auto-increments per account starting at zero" do
    first = @account.rooms.create!(name: "First")
    second = @account.rooms.create!(name: "Second")
    third = @account.rooms.create!(name: "Third")

    assert_equal [ 0, 1, 2 ], [ first, second, third ].map(&:position)

    # A fresh account starts its own count at zero too.
    other_first = accounts(:other).rooms.create!(name: "Other first")
    assert_equal 0, other_first.position
  end

  test "move! swaps with the neighbour in the given direction and no-ops at the ends" do
    a = @account.rooms.create!(name: "A")
    b = @account.rooms.create!(name: "B")
    c = @account.rooms.create!(name: "C")

    a.move!(-1) # already first: no-op
    assert_equal [ 0, 1, 2 ], [ a, b, c ].map { |room| room.reload.position }

    b.move!(-1) # swap B and A
    assert_equal [ 1, 0, 2 ], [ a.reload, b.reload, c.reload ].map(&:position)
    assert_equal [ b, a, c ], @account.rooms.ordered.to_a

    c.move!(1) # already last: no-op
    assert_equal [ 1, 0, 2 ], [ a.reload, b.reload, c.reload ].map(&:position)

    b.move!(1) # swap B back past A
    assert_equal [ 0, 1, 2 ], [ a.reload, b.reload, c.reload ].map(&:position)
    assert_equal [ a, b, c ], @account.rooms.ordered.to_a
  end

  test "destroying a room nullifies its chats' room without deleting them" do
    room = @account.rooms.create!(name: "Life")
    kept = @account.chats.create!(title: "Keep me", model_id: "openrouter/auto", room: room)
    archived = @account.chats.create!(title: "Archived", model_id: "openrouter/auto", room: room)
    archived.archive!
    discarded = @account.chats.create!(title: "Deleted", model_id: "openrouter/auto", room: room)
    discarded.discard!

    assert_no_difference "Chat.count" do
      room.destroy!
    end
    [ kept, archived, discarded ].each { |chat| assert_nil chat.reload.room_id }
    assert_equal "Keep me", kept.title
  end

  test "a chat cannot take a room from another account" do
    chat = @account.chats.create!(title: "Mine", model_id: "openrouter/auto")
    foreign_room = accounts(:other).rooms.create!(name: "Elsewhere")

    assert_not chat.update(room: foreign_room)
    assert chat.errors[:room].any?

    assert_raises(ActiveRecord::InvalidForeignKey) do
      Chat.transaction(requires_new: true) { chat.update_columns(room_id: foreign_room.id) }
    end
  end

  test "an account's resident_room must belong to the account" do
    foreign_room = accounts(:other).rooms.create!(name: "Elsewhere")

    assert_not @account.update(resident_room: foreign_room)
    assert @account.errors[:resident_room].any?

    own_room = @account.rooms.create!(name: "Mine")
    assert @account.update(resident_room: own_room)
  end

  test "public representation is stable and resolve_for scopes to the account" do
    room = @account.rooms.create!(name: "Life")
    id = room.to_param
    room.update!(name: "Renewed")
    assert_equal id, room.reload.to_param
    assert_equal({ "id" => id, "name" => "Renewed" }, room.as_json)

    assert_equal room, Room.resolve_for(@account, id)
    assert_nil Room.resolve_for(@account, nil)

    foreign = accounts(:other).rooms.create!(name: "Foreign")
    [ foreign.to_param, room.id, room.id.to_s, "", [], {}, "unknown", "has1digit" ].each do |invalid|
      assert_raises(ActiveRecord::RecordNotFound) { Room.resolve_for(@account, invalid) }
    end
  end


  test "moving a flagged conversation, or removing its room, refreshes its viewers' attention" do
    account = accounts(:personal_account)
    user = users(:user_1)
    room = account.rooms.create!(name: "Flagged")
    chat = account.chats.create!(title: "Flagged", model_id: "openrouter/auto")
    message = chat.messages.create!(role: "assistant", content: "Over to you?")
    ReplyExpectation.record!(message: message, user: user, score: 1.0,
      classifier_version: ReplyExpectation::DIRECT_MENTION_VERSION)

    refreshed = []
    ReplyExpectation.stub(:refresh_for, ->(uid) { refreshed << uid }) do
      chat.update!(room: room)
      assert_includes refreshed, user.id

      refreshed.clear
      room.destroy!
      assert_includes refreshed, user.id
    end
    assert_nil chat.reload.room
  end

end
