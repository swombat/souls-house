require "test_helper"

class Accounts::RoomsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    @account = accounts(:team_account)
    sign_in @user
  end

  test "index renders rooms with conversation counts and the resident default for a member" do
    life = @account.rooms.create!(name: "Life")
    work = @account.rooms.create!(name: "Work")
    @account.update!(resident_room: life)
    @account.chats.create!(title: "In Life", model_id: "openrouter/auto", room: life)
    @account.chats.create!(title: "Also Life", model_id: "openrouter/auto", room: life)
    @account.chats.create!(title: "No room", model_id: "openrouter/auto")
    @account.chats.create!(title: "Deleted", model_id: "openrouter/auto", room: work).discard!

    get account_rooms_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }

    assert_response :success
    assert_equal "accounts/rooms", inertia_component
    assert_equal true, inertia_shared_props["can_manage"]
    assert_equal 1, inertia_shared_props["main_count"]
    assert_equal life.to_param, inertia_shared_props["resident_room_id"]

    rows = inertia_shared_props.fetch("rooms")
    assert_equal [ life.directory_json, work.directory_json ], rows
    assert_equal({ life.to_param => 2 }, inertia_shared_props.fetch("room_counts"))
  end

  test "counts and resident preference refresh independently of room metadata" do
    life = @account.rooms.create!(name: "Life")
    work = @account.rooms.create!(name: "Work")
    chat = @account.chats.create!(title: "In Life", model_id: "openrouter/auto", room: life)
    @account.update!(resident_room: life)
    get account_rooms_path(@account)
    assert_response :success
    version = inertia_props.fetch("version")
    headers = {
      "X-Inertia" => "true",
      "X-Inertia-Version" => version,
      "X-Inertia-Partial-Component" => "accounts/rooms",
      "X-Inertia-Partial-Data" => "room_counts,main_count,resident_room_id"
    }

    chat.update!(room: work)
    @account.update!(resident_room: work)
    get account_rooms_path(@account), headers: headers
    assert_response :success
    props = response.parsed_body.fetch("props")
    assert_equal({ work.to_param => 1 }, props.fetch("room_counts"))
    assert_equal 0, props.fetch("main_count")
    assert_equal work.to_param, props.fetch("resident_room_id")
    assert_not props.key?("rooms")
    assert_not props.key?("current_room")

    chat.update!(room: nil)
    get account_rooms_path(@account), headers: headers
    assert_response :success
    props = response.parsed_body.fetch("props")
    assert_empty props.fetch("room_counts")
    assert_equal 1, props.fetch("main_count")
    assert_not props.key?("rooms")

    work.update!(name: "Office")
    get account_rooms_path(@account), headers: headers.merge("X-Inertia-Partial-Data" => "rooms,current_room")
    assert_response :success
    props = response.parsed_body.fetch("props")
    assert_equal [ life.directory_json, work.directory_json ], props.fetch("rooms")
    assert_equal "main", props.fetch("current_room")
    assert_not props.key?("room_counts")
    assert_not props.key?("main_count")
    assert_not props.key?("resident_room_id")
  end

  test "create adds a room scoped to the account, requires a manager, and reports validation errors" do
    assert_difference "@account.rooms.count", 1 do
      post account_rooms_path(@account), params: { room: { name: "Life" } }
    end
    assert_redirected_to account_rooms_path(@account)
    assert_equal @account, Room.last.account

    assert_no_difference "Room.count" do
      post account_rooms_path(@account), params: { room: { name: "Main" } }
    end
    assert_redirected_to account_rooms_path(@account)
    follow_redirect!
    assert inertia_shared_props.fetch("errors").fetch("name").present?

    assert_no_difference "Room.count" do
      post account_rooms_path(@account), params: { room: { name: "life" } } # case-insensitive clash
    end
    follow_redirect!
    assert inertia_shared_props.fetch("errors").fetch("name").present?

    memberships(:team_member).update_columns(confirmed_at: nil)
    assert_no_difference "Room.count" do
      post account_rooms_path(@account), params: { room: { name: "Pending" } }
    end
    assert_response :not_found
  end

  test "update renames a room, requires a manager, and reports validation errors" do
    room = @account.rooms.create!(name: "Life")

    patch account_room_path(@account, room), params: { room: { name: "Renamed" } }
    assert_redirected_to account_rooms_path(@account)
    assert_equal "Renamed", room.reload.name

    patch account_room_path(@account, room), params: { room: { name: "Renamed", description: "home things" } }
    assert_redirected_to account_rooms_path(@account)
    assert_equal "home things", room.reload.description

    patch account_room_path(@account, room), params: { room: { name: "Main" } }
    follow_redirect!
    assert inertia_shared_props.fetch("errors").fetch("name").present?
    assert_equal "Renamed", room.reload.name

    other = accounts(:other)
    foreign = other.rooms.create!(name: "Foreign")
    patch account_room_path(other, foreign), params: { room: { name: "Stolen" } }
    assert_response :not_found

    memberships(:team_member).update_columns(confirmed_at: nil)
    patch account_room_path(@account, room), params: { room: { name: "Nope" } }
    assert_response :not_found
    assert_equal "Renamed", room.reload.name
  end

  test "reorder moves a room up or down among its siblings" do
    a = @account.rooms.create!(name: "A")
    b = @account.rooms.create!(name: "B")

    patch account_room_path(@account, b), params: { direction: "up" }
    assert_redirected_to account_rooms_path(@account)
    assert_equal [ b, a ], @account.rooms.ordered.to_a

    patch account_room_path(@account, b), params: { direction: "down" }
    assert_equal [ a, b ], @account.rooms.ordered.to_a
  end

  test "destroy removes the room, requires a manager, and keeps its conversations" do
    room = @account.rooms.create!(name: "Life")
    chat = @account.chats.create!(title: "Stays", model_id: "openrouter/auto", room: room)

    other = accounts(:other)
    foreign = other.rooms.create!(name: "Foreign")
    delete account_room_path(other, foreign)
    assert_response :not_found
    assert Room.exists?(foreign.id)

    memberships(:team_member).update_columns(confirmed_at: nil)
    delete account_room_path(@account, room)
    assert_response :not_found
    assert Room.exists?(room.id)
    memberships(:team_member).update_columns(confirmed_at: 1.day.ago)

    assert_no_difference "Chat.count" do
      assert_difference "Room.count", -1 do
        delete account_room_path(@account, room)
      end
    end
    assert_redirected_to account_rooms_path(@account)
    assert_nil chat.reload.room_id
    assert_equal "Stays", chat.title
  end

  test "anonymous requests require sign in" do
    delete logout_path
    get account_rooms_path(@account)
    assert_redirected_to login_path
  end

end
