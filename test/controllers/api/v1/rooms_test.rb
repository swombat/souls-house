require "test_helper"

module Api
  module V1
    class RoomsTest < ActionDispatch::IntegrationTest

      setup do
        @daniel = users(:user_1)
        @home = accounts(:personal_account)
        @nexus = accounts(:team_account)
        @agent = agents(:research_assistant) # home: personal_account
        @agent_headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@daniel, name: "Agent", agent: @agent).raw_token}" }
        @account_headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@daniel, name: "Account", account: @home).raw_token}" }
      end

      test "a resident lists its home rooms, Main first, with what each is for and the resident default" do
        life = @home.rooms.create!(name: "Life", description: "personal things")
        @home.update!(resident_room: life)

        get api_v1_rooms_url, headers: @agent_headers
        assert_response :success
        assert_equal [
          { "id" => nil, "name" => "Main", "description" => nil },
          { "id" => life.to_param, "name" => "Life", "description" => "personal things" }
        ], response.parsed_body["rooms"]
        assert_equal({ "id" => life.to_param, "name" => "Life" }, response.parsed_body["resident_room"])
      end

      test "a renamed Main is listed under its name, with its description" do
        @home.update!(main_room_name: "General", main_room_description: "anything without a better home")

        get api_v1_rooms_url, headers: @agent_headers
        assert_response :success
        assert_equal({ "id" => nil, "name" => "General", "description" => "anything without a better home" },
          response.parsed_body["rooms"].first)
        assert_equal({ "id" => nil, "name" => "General" }, response.parsed_body["resident_room"])
      end

      test "a resident adds a room at home" do
        assert_difference -> { @home.rooms.count } do
          post api_v1_rooms_url, params: { name: "Build", description: "technical work" }, headers: @agent_headers, as: :json
        end
        assert_response :created
        assert_equal({ "name" => "Build", "description" => "technical work" }, response.parsed_body["room"].except("id"))
        assert AuditLog.exists?(action: "create_room", account: @home)
      end

      test "a seated guest lists and adds rooms in the guest account, not its home" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        @home.rooms.create!(name: "Private Home Room")

        post api_v1_rooms_url, params: { account_id: @nexus.to_param, name: "Build" }, headers: @agent_headers, as: :json
        assert_response :created
        assert @nexus.rooms.exists?(name: "Build")

        get api_v1_rooms_url, params: { account_id: @nexus.to_param }, headers: @agent_headers
        assert_response :success
        assert_equal %w[Main Build], response.parsed_body["rooms"].map { |room| room["name"] }
      end

      test "an account the resident is not a guest of is 404, and a guest that left loses the rooms" do
        get api_v1_rooms_url, params: { account_id: @nexus.to_param }, headers: @agent_headers
        assert_response :not_found

        membership = @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        get api_v1_rooms_url, params: { account_id: @nexus.to_param }, headers: @agent_headers
        assert_response :success

        membership.destroy!
        post api_v1_rooms_url, params: { account_id: @nexus.to_param, name: "Late" }, headers: @agent_headers, as: :json
        assert_response :not_found
        assert_not @nexus.rooms.exists?(name: "Late")
      end

      test "invalid and duplicate names are 422" do
        @home.rooms.create!(name: "Build")

        [ "Main", "", "build" ].each do |name|
          post api_v1_rooms_url, params: { name: name }, headers: @agent_headers, as: :json
          assert_response :unprocessable_entity, name.inspect
        end
        post api_v1_rooms_url, params: { name: "Long", description: "x" * 281 }, headers: @agent_headers, as: :json
        assert_response :unprocessable_entity
      end

      test "an account key lists and adds rooms in its own account" do
        post api_v1_rooms_url, params: { name: "From Key" }, headers: @account_headers, as: :json
        assert_response :created
        assert @home.rooms.exists?(name: "From Key")

        get api_v1_rooms_url, headers: @account_headers
        assert_includes response.parsed_body["rooms"].map { |room| room["name"] }, "From Key"
      end

      test "a person's key stops when they leave the account, reads included" do
        membership = memberships(:team_member)
        headers = { "Authorization" => "Bearer #{ApiKey.generate_for(membership.user, name: "Member", account: @nexus).raw_token}" }
        get api_v1_rooms_url, headers: headers
        assert_response :success

        membership.destroy!

        get api_v1_rooms_url, headers: headers
        assert_response :not_found
        post api_v1_rooms_url, params: { name: "After leaving" }, headers: headers, as: :json
        assert_response :not_found
        assert_not @nexus.rooms.exists?(name: "After leaving")
      end

      test "a person's key stops when their membership is unconfirmed" do
        memberships(:daniel_personal).update_columns(confirmed_at: nil)

        get api_v1_rooms_url, headers: @account_headers
        assert_response :not_found
        post api_v1_rooms_url, params: { name: "Unconfirmed" }, headers: @account_headers, as: :json
        assert_response :not_found
        assert_not @home.rooms.exists?(name: "Unconfirmed")
      end

      test "a disabled account's key is not found, for reads and writes" do
        @home.update_columns(disabled_at: Time.current)

        get api_v1_rooms_url, headers: @account_headers
        assert_response :not_found
        post api_v1_rooms_url, params: { name: "Closed" }, headers: @account_headers, as: :json
        assert_response :not_found
        assert_not @home.rooms.exists?(name: "Closed")
      end

      test "a resident renames and describes a room at home, audited with the resident named" do
        room = @home.rooms.create!(name: "Build", description: "old")

        patch api_v1_room_url(room), params: { name: "Dev", description: "technical work" }, headers: @agent_headers, as: :json
        assert_response :success
        assert_equal({ "id" => room.to_param, "name" => "Dev", "description" => "technical work" }, response.parsed_body["room"])
        assert_equal %w[Main Dev], response.parsed_body["rooms"].map { |r| r["name"] }
        log = AuditLog.find_by!(action: "update_room", auditable: room)
        assert_equal @agent.to_param, log.data["agent_id"]
        assert_equal [ "Build", "Dev" ], log.data["name"]

        patch api_v1_room_url(room), params: { description: "only this" }, headers: @agent_headers, as: :json
        assert_response :success
        assert_equal [ "Dev", "only this" ], [ room.reload.name, room.description ]
      end

      test "a resident moves a room up and down" do
        a = @home.rooms.create!(name: "A")
        b = @home.rooms.create!(name: "B")

        patch api_v1_room_url(b), params: { direction: "up" }, headers: @agent_headers, as: :json
        assert_response :success
        assert_equal %w[Main B A], response.parsed_body["rooms"].map { |r| r["name"] }

        patch api_v1_room_url(b), params: { direction: "down" }, headers: @agent_headers, as: :json
        assert_equal %w[Main A B], response.parsed_body["rooms"].map { |r| r["name"] }

        patch api_v1_room_url(a), params: { direction: "sideways" }, headers: @agent_headers, as: :json
        assert_response :unprocessable_entity
      end

      test "renaming to a taken name or Main is 422 and changes nothing" do
        @home.rooms.create!(name: "Build")
        room = @home.rooms.create!(name: "Life")

        [ "build", "Main", "" ].each do |name|
          patch api_v1_room_url(room), params: { name: name }, headers: @agent_headers, as: :json
          assert_response :unprocessable_entity, name.inspect
        end
        assert_equal "Life", room.reload.name
      end

      test "a resident removes a room; its conversations move to Main and the default falls back to Main" do
        room = @home.rooms.create!(name: "Life")
        chats = 2.times.map { |i| @home.chats.create!(title: "In Life #{i}", model_id: "openrouter/auto", room: room) }
        @home.update!(resident_room: room)

        assert_difference -> { @home.rooms.count }, -1 do
          delete api_v1_room_url(room), headers: @agent_headers, as: :json
        end
        assert_response :success
        assert_equal 2, response.parsed_body["moved_conversations"]
        assert_equal "Main", response.parsed_body["moved_to"]
        assert_equal "Life", response.parsed_body.dig("removed", "name")
        assert_equal({ "id" => nil, "name" => "Main" }, response.parsed_body["resident_room"])
        chats.each { |chat| assert_nil chat.reload.room_id }
        assert_nil @home.reload.resident_room_id
        assert AuditLog.exists?(action: "destroy_room", account: @home)
      end

      test "a resident renames and describes Main" do
        patch main_api_v1_rooms_url, params: { name: "General", description: "anything else" }, headers: @agent_headers, as: :json
        assert_response :success
        assert_equal({ "id" => nil, "name" => "General", "description" => "anything else" }, response.parsed_body["room"])
        assert_equal "General", @home.reload.main_room_label
        assert AuditLog.exists?(action: "update_main_room", account: @home)
      end

      test "a resident sets the default room for resident-started conversations, and back to Main" do
        life = @home.rooms.create!(name: "Life")

        patch resident_room_api_v1_rooms_url, params: { room_id: life.to_param }, headers: @agent_headers, as: :json
        assert_response :success
        assert_equal({ "id" => life.to_param, "name" => "Life" }, response.parsed_body["resident_room"])
        assert_equal life, @home.reload.resident_room

        patch resident_room_api_v1_rooms_url, params: { room_id: nil }, headers: @agent_headers, as: :json
        assert_response :success
        assert_nil @home.reload.resident_room

        patch resident_room_api_v1_rooms_url, params: {}, headers: @agent_headers, as: :json
        assert_response :unprocessable_entity
        patch resident_room_api_v1_rooms_url, params: { room_id: "nope" }, headers: @agent_headers, as: :json
        assert_response :not_found
      end

      test "a resident sets and clears a room's starting model for a resident" do
        @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
        build = @home.rooms.create!(name: "Build")

        patch model_default_api_v1_rooms_url,
          params: { room_id: build.to_param, agent_id: @agent.to_param, model_id: "anthropic/claude-fable-5.1" },
          headers: @agent_headers, as: :json
        assert_response :success
        assert_equal "anthropic/claude-fable-5.1", response.parsed_body.dig("room_model_default", "model_id")
        assert_equal %w[Main Build], response.parsed_body["rooms"].map { |r| r["name"] }
        assert_equal 1, response.parsed_body["room_model_defaults"].size
        assert_equal "anthropic/claude-fable-5.1", RoomModelDefault.find_by!(room: build, agent: @agent).model_id

        patch model_default_api_v1_rooms_url,
          params: { room_id: "main", agent_id: @agent.to_param, model_id: "anthropic/claude-haiku-5.5" },
          headers: @agent_headers, as: :json
        assert_response :unprocessable_entity

        patch model_default_api_v1_rooms_url,
          params: { room_id: build.to_param, agent_id: @agent.to_param, model_id: "default" },
          headers: @agent_headers, as: :json
        assert_response :success
        assert_nil response.parsed_body["room_model_default"]
        assert_not RoomModelDefault.exists?(room: build)
      end

      test "a seated guest manages the guest account's rooms, and not its home's through that account" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        room = @nexus.rooms.create!(name: "Build")
        home_room = @home.rooms.create!(name: "Home Only")

        patch api_v1_room_url(room), params: { account_id: @nexus.to_param, name: "Dev" }, headers: @agent_headers, as: :json
        assert_response :success
        assert_equal "Dev", room.reload.name

        patch api_v1_room_url(home_room), params: { account_id: @nexus.to_param, name: "Moved" }, headers: @agent_headers, as: :json
        assert_response :not_found

        patch resident_room_api_v1_rooms_url, params: { account_id: @nexus.to_param, room_id: room.to_param },
          headers: @agent_headers, as: :json
        assert_response :success
        assert_equal room, @nexus.reload.resident_room

        patch main_api_v1_rooms_url, params: { account_id: @nexus.to_param, name: "Lobby" }, headers: @agent_headers, as: :json
        assert_response :success
        assert_equal "Lobby", @nexus.reload.main_room_label

        delete api_v1_room_url(room), params: { account_id: @nexus.to_param }, headers: @agent_headers, as: :json
        assert_response :success
        assert_not Room.exists?(room.id)
      end

      test "a resident with no seat in the account changes nothing there" do
        room = @nexus.rooms.create!(name: "Build")

        patch api_v1_room_url(room), params: { account_id: @nexus.to_param, name: "Mine" }, headers: @agent_headers, as: :json
        assert_response :not_found
        delete api_v1_room_url(room), params: { account_id: @nexus.to_param }, headers: @agent_headers, as: :json
        assert_response :not_found
        patch main_api_v1_rooms_url, params: { account_id: @nexus.to_param, name: "Mine" }, headers: @agent_headers, as: :json
        assert_response :not_found
        patch resident_room_api_v1_rooms_url, params: { account_id: @nexus.to_param, room_id: room.to_param },
          headers: @agent_headers, as: :json
        assert_response :not_found

        patch api_v1_room_url(room), params: { name: "Mine" }, headers: @agent_headers, as: :json
        assert_response :not_found, "a room in another account is not reachable from home either"
        assert_equal "Build", room.reload.name
      end

      test "an account key changes rooms in its own account; a former member's key changes nothing" do
        room = @home.rooms.create!(name: "Build")
        patch api_v1_room_url(room), params: { name: "Dev" }, headers: @account_headers, as: :json
        assert_response :success
        delete api_v1_room_url(room), headers: @account_headers, as: :json
        assert_response :success

        membership = memberships(:team_member)
        headers = { "Authorization" => "Bearer #{ApiKey.generate_for(membership.user, name: "Member", account: @nexus).raw_token}" }
        nexus_room = @nexus.rooms.create!(name: "Kept")
        membership.destroy!
        patch api_v1_room_url(nexus_room), params: { name: "Gone" }, headers: headers, as: :json
        assert_response :not_found
        delete api_v1_room_url(nexus_room), headers: headers, as: :json
        assert_response :not_found
        assert Room.exists?(nexus_room.id)
      end

      test "GET shows the residents a room can start on another model, their choices, and the current room choices" do
        @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
        build = @home.rooms.create!(name: "Build")
        RoomModelDefault.set!(account: @home, room: build, agent: @agent, model_id: "anthropic/claude-fable-5.1")

        get api_v1_rooms_url, headers: @agent_headers
        assert_response :success
        resident = response.parsed_body["model_residents"].find { |r| r["id"] == @agent.to_param }
        assert resident, "the switchable resident is listed"
        assert_equal @agent.model_label, resident["default_label"]
        assert resident["choices"].any?, "with its choices"
        assert_equal [ { "room_id" => build.to_param, "agent_id" => @agent.to_param, "model_id" => "anthropic/claude-fable-5.1" } ],
          response.parsed_body["room_model_defaults"].map { |d| d.slice("room_id", "agent_id", "model_id") }
      end

      test "a guest reads the guest account's model settings, not its home's" do
        @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
        RoomModelDefault.set!(account: @home, room: nil, agent: @agent, model_id: "anthropic/claude-fable-5.1")
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)

        get api_v1_rooms_url, params: { account_id: @nexus.to_param }, headers: @agent_headers
        assert_response :success
        assert_equal [], response.parsed_body["room_model_defaults"]
        assert_not_includes response.parsed_body["model_residents"].map { |r| r["id"] }, @agent.to_param
      end

    end
  end
end
