require "test_helper"

# Where a rhythm's occurrences open: the account's resident default room, Main
# on purpose, or a named room, with a removed room falling back to the default.
class RhythmRoomTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @account = @agent.account
    @now = Time.utc(2026, 10, 3, 10)
    @build = @account.rooms.create!(name: "Build")
    @planning = @account.rooms.create!(name: "Planning")
    @rhythm = Rhythm.create!(
      account: @account, creator: @user, title: "Morning look", opening: "What is taking shape?",
      agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC",
      next_run_at: @now - 1.day
    )
  end

  test "a new rhythm follows the account's resident default room" do
    assert_equal "resident_default", @rhythm.room_choice
    @account.update!(resident_room: @build)

    assert_equal @build, fire.chat.room
  end

  test "following the default opens in Main while the account has none" do
    assert_nil @account.resident_room
    assert_nil fire.chat.room
  end

  test "Main on purpose ignores the account default" do
    @account.update!(resident_room: @build)
    @rhythm.update!(room_choice: "main")

    assert_nil fire.chat.room
  end

  test "a named room opens there whatever the default is" do
    @account.update!(resident_room: @build)
    @rhythm.update!(room_choice: "room", room_public_id: @planning.to_param)

    assert_equal @planning, fire.chat.room
  end

  test "choosing another kind clears the named room" do
    @rhythm.update!(room_choice: "room", room_public_id: @planning.to_param)
    @rhythm.update!(room_choice: "main")

    assert_nil @rhythm.reload.room_id
  end

  test "a removed room falls back to the account default and says so" do
    @account.update!(resident_room: @build)
    @rhythm.update!(room_choice: "room", room_public_id: @planning.to_param)
    @planning.destroy!
    @rhythm.reload

    assert @rhythm.room_removed?
    assert_equal "room", @rhythm.room_choice
    assert_equal @build, fire.chat.room
    payload = RhythmPresentation.new(@rhythm.reload, user: @user).as_json
    assert payload[:room_removed]
    assert_equal "Build", payload[:opens_in]["name"]
  end

  test "a rhythm whose room was removed still saves other edits" do
    @rhythm.update!(room_choice: "room", room_public_id: @planning.to_param)
    @planning.destroy!
    @rhythm.reload

    assert @rhythm.update(title: "Morning look, again")
    assert @rhythm.room_removed?
  end

  test "a named room must be chosen" do
    @rhythm.room_choice = "room"

    assert_not @rhythm.valid?
    assert_includes @rhythm.errors[:room], "must be chosen"
  end

  test "a room of another account is refused on create and on update" do
    other_account = Account.where.not(id: @account.id).first!
    foreign = other_account.rooms.create!(name: "Elsewhere")

    created = Rhythm.new(
      account: @account, creator: @user, title: "Elsewhere", opening: "Hello",
      agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC",
      room_choice: "room", room_public_id: foreign.to_param
    )
    assert_not created.save
    assert_includes created.errors[:room], "must be a room of this account"

    assert_not @rhythm.update(room_choice: "room", room_public_id: foreign.to_param)
    assert_includes @rhythm.errors[:room], "must be a room of this account"
    assert_nil @rhythm.reload.room_id
  end

  test "a value that is not a room id is refused rather than dropped" do
    [ "nonsense1", @planning.id.to_s, "zzzzzzzzzz" ].each do |value|
      assert_not @rhythm.update(room_choice: "room", room_public_id: value), value
      assert_includes @rhythm.errors[:room], "must be a room of this account"
    end
  end

  test "an unknown choice is refused" do
    @rhythm.room_choice = "somewhere"

    assert_not @rhythm.valid?
    assert @rhythm.errors[:room_choice].present?
  end


  test "a room id is resolved within the account even when assigned before it" do
    rhythm = Rhythm.new(room_choice: "room", room_public_id: @planning.to_param, account: @account, creator: @user,
      title: "Late account", opening: "Hello", agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC")
    assert rhythm.save, rhythm.errors.full_messages.to_sentence
    assert_equal @planning, rhythm.room

    foreign = Account.where.not(id: @account.id).first!.rooms.create!(name: "Elsewhere")
    other = Rhythm.new(room_choice: "room", room_public_id: foreign.to_param, account: @account, creator: @user,
      title: "Late account", opening: "Hello", agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC")
    assert_not other.save
    assert_nil other.room
  end

  private

  def fire
    @rhythm.update_column(:next_run_at, @now - 1.hour)
    result = @rhythm.fire!(now: @now)
    assert_equal :created, result.status, result.reason
    result.occurrence
  end

end
