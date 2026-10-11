require "test_helper"

class ChatsControllerRoomsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @life = @account.rooms.create!(name: "Life")
    @work = @account.rooms.create!(name: "Work")
    @main_chat = @account.chats.create!(title: "Main chat", model_id: "openrouter/auto")
    @life_chat = @account.chats.create!(title: "Life chat", model_id: "openrouter/auto", room: @life)
    @work_chat = @account.chats.create!(title: "Work chat", model_id: "openrouter/auto", room: @work)
    sign_in @user
  end

  def inertia_headers
    { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
  end

  test "index defaults to Main: only room-less chats" do
    get account_chats_path(@account), headers: inertia_headers
    assert_response :success
    ids = inertia_shared_props.fetch("chats").pluck("id")
    assert_includes ids, @main_chat.to_param
    assert_not_includes ids, @life_chat.to_param
    assert_not_includes ids, @work_chat.to_param
    assert_equal "main", inertia_shared_props["current_room"]
  end

  test "index with ?room=<id> lists only that room's chats" do
    get account_chats_path(@account, room: @life.to_param), headers: inertia_headers
    assert_response :success
    assert_equal [ @life_chat.to_param ], inertia_shared_props.fetch("chats").pluck("id")
    assert_equal @life.to_param, inertia_shared_props["current_room"]
  end

  test "index with ?room=all lists every room's chats" do
    get account_chats_path(@account, room: "all"), headers: inertia_headers
    assert_response :success
    ids = inertia_shared_props.fetch("chats").pluck("id")
    assert_includes ids, @main_chat.to_param
    assert_includes ids, @life_chat.to_param
    assert_includes ids, @work_chat.to_param
    assert_equal "all", inertia_shared_props["current_room"]
  end

  test "the room selection persists across requests via the session" do
    get account_chats_path(@account, room: @work.to_param), headers: inertia_headers
    @inertia_props = nil
    get account_chats_path(@account), headers: inertia_headers
    assert_equal [ @work_chat.to_param ], inertia_shared_props.fetch("chats").pluck("id")
    assert_equal @work.to_param, inertia_shared_props["current_room"]
  end

  test "a conversation opens in its own room; only a click from All chats keeps All" do
    get account_chats_path(@account), headers: inertia_headers # Main
    get account_chat_path(@account, @life_chat), headers: inertia_headers
    assert_response :success
    assert_equal @life.to_param, inertia_shared_props["current_room"]

    @inertia_props = nil
    get account_chats_path(@account), headers: inertia_headers
    assert_equal [ @life_chat.to_param ], inertia_shared_props.fetch("chats").pluck("id")

    # A click from the All chats list carries room=all and keeps All.
    get account_chats_path(@account, room: "all"), headers: inertia_headers
    @inertia_props = nil
    get account_chat_path(@account, @work_chat, room: "all"), headers: inertia_headers
    assert_equal "all", inertia_shared_props["current_room"]

    # A bare link never inherits the earlier All selection.
    @inertia_props = nil
    get account_chat_path(@account, @work_chat), headers: inertia_headers
    assert_equal @work.to_param, inertia_shared_props["current_room"]
  end

  test "create puts the new chat in the room being viewed" do
    get account_chats_path(@account, room: @work.to_param), headers: inertia_headers

    post account_chats_path(@account), params: { agent_ids: [ @agent.to_param ] }
    assert_equal @work, Chat.last.room
  end

  test "create honours an explicit room_id over the viewed room, including clearing it to Main" do
    get account_chats_path(@account, room: @work.to_param), headers: inertia_headers

    post account_chats_path(@account), params: { agent_ids: [ @agent.to_param ], room_id: @life.to_param }
    assert_equal @life, Chat.last.room

    post account_chats_path(@account), params: { agent_ids: [ @agent.to_param ], room_id: "" }
    assert_nil Chat.last.room
  end

  test "create while viewing All without an explicit room leaves the chat in Main" do
    get account_chats_path(@account, room: "all"), headers: inertia_headers

    post account_chats_path(@account), params: { agent_ids: [ @agent.to_param ] }
    assert_nil Chat.last.room
  end

  test "shared inertia props expose the account's rooms in position order" do
    get account_chats_path(@account), headers: inertia_headers
    assert_equal [ @life.as_json, @work.as_json ], inertia_shared_props["rooms"]
  end


  test "an in-place action from All chats returns to All; the same action outside All stays in the room" do
    get account_chat_path(@account, @work_chat, room: "all"), headers: inertia_headers
    patch account_chat_path(@account, @work_chat), params: { chat: { title: "Renamed" } }
    assert_redirected_to account_chat_path(@account, @work_chat, room: "all")
    @inertia_props = nil
    get response.location, headers: inertia_headers
    assert_equal "all", inertia_shared_props["current_room"]

    get account_chat_path(@account, @life_chat), headers: inertia_headers
    patch account_chat_path(@account, @life_chat), params: { chat: { title: "Renamed too" } }
    assert_redirected_to account_chat_path(@account, @life_chat)
  end

  test "a partial sidebar reload carries the selection that matches its contents" do
    get account_chat_path(@account, @life_chat), headers: inertia_headers
    @life_chat.update!(room: @work) # moved by another client

    @inertia_props = nil
    get account_chat_path(@account, @life_chat), headers: inertia_headers.merge(
      "X-Inertia-Partial-Component" => "chats/show", "X-Inertia-Partial-Data" => "chats,current_room"
    )
    assert_equal @work.to_param, inertia_shared_props["current_room"]
    assert_includes inertia_shared_props.fetch("chats").pluck("id"), @life_chat.to_param
  end

end
