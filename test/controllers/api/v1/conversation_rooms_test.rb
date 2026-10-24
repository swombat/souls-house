require "test_helper"

module Api
  module V1
    class ConversationRoomsTest < ActionDispatch::IntegrationTest

      setup do
        @daniel = users(:user_1)
        @home = accounts(:personal_account)
        @nexus = accounts(:team_account)
        @life = @home.rooms.create!(name: "Life")
        @agent = agents(:research_assistant) # home account: personal_account
        @local = agents(:other_account_agent) # home account: team_account
        @account_token = ApiKey.generate_for(@daniel, name: "Account", account: @home).raw_token
        @agent_token = ApiKey.generate_for(@daniel, name: "Agent", agent: @agent).raw_token
      end

      test "a resident key at home with an explicit room name lands the conversation there" do
        post api_v1_conversations_url, params: { room: "Life" },
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created

        chat = Chat.find(response.parsed_body.dig("conversation", "id"))
        assert_equal @life, chat.room
        assert_equal({ "id" => @life.to_param, "name" => "Life" }, response.parsed_body.dig("conversation", "room"))
      end

      test "a room named after another room's public id never shadows that id" do
        decoy = @home.rooms.create!(name: @life.to_param)

        post api_v1_conversations_url, params: { room_id: @life.to_param },
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created
        assert_equal @life, Chat.find(response.parsed_body.dig("conversation", "id")).room

        post api_v1_conversations_url, params: { room: @life.to_param },
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created
        assert_equal decoy, Chat.find(response.parsed_body.dig("conversation", "id")).room
      end

      test "room and room_id together are refused and create nothing" do
        assert_no_difference -> { Chat.count } do
          post api_v1_conversations_url, params: { room: "Life", room_id: @life.to_param },
            headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        end
        assert_response :unprocessable_entity
        assert_equal "invalid_room_selector", response.parsed_body["code"]
      end

      test "a resident key at home with an explicit room public id lands the conversation there" do
        post api_v1_conversations_url, params: { room_id: @life.to_param },
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created
        assert_equal @life, Chat.find(response.parsed_body.dig("conversation", "id")).room
      end

      test "without room a resident key at home lands in the account's resident default" do
        @home.update!(resident_room: @life)
        post api_v1_conversations_url, params: {},
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created
        assert_equal @life, Chat.find(response.parsed_body.dig("conversation", "id")).room
      end

      test "without a resident_room default, a resident key at home lands in Main" do
        post api_v1_conversations_url, params: {},
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created
        assert_nil Chat.find(response.parsed_body.dig("conversation", "id")).room
        assert_equal({ "id" => nil, "name" => "Main" }, response.parsed_body.dig("conversation", "room"))
      end

      test "a seated guest resident may choose a room when it starts a conversation there" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        build = @nexus.rooms.create!(name: "Build")
        @nexus.update!(resident_room: @nexus.rooms.create!(name: "Default"))

        post api_v1_conversations_url,
          params: { account_id: @nexus.to_param, room: "Build", agent_ids: [ @local.to_param ] },
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created

        json = response.parsed_body.fetch("conversation")
        assert_equal build, Chat.find(json["id"]).room
        assert_equal({ "id" => build.to_param, "name" => "Build" }, json["room"])
      end

      test "a guest's room selector never reaches a room of its home account" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)

        assert_no_difference -> { Chat.count } do
          post api_v1_conversations_url,
            params: { account_id: @nexus.to_param, room_id: @life.to_param, agent_ids: [ @local.to_param ] },
            headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        end
        assert_response :not_found
      end

      test "a guest resident without a room lands in the account's resident default" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        guest_default = @nexus.rooms.create!(name: "Guest Room")
        @nexus.update!(resident_room: guest_default)

        post api_v1_conversations_url,
          params: { account_id: @nexus.to_param, agent_ids: [ @local.to_param ] },
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created

        json = response.parsed_body.fetch("conversation")
        assert_equal guest_default, Chat.find(json["id"]).room
        assert_equal({ "id" => guest_default.to_param, "name" => "Guest Room" }, json["room"])
      end

      test "conversation JSON includes room id and name for a home caller, even an account key" do
        post api_v1_conversations_url, params: { agent_ids: [ @agent.to_param ] },
          headers: { "Authorization" => "Bearer #{@account_token}" }
        assert_response :created
        assert_equal({ "id" => nil, "name" => "Main" }, response.parsed_body.dig("conversation", "room"))

        chat_id = response.parsed_body.dig("conversation", "id")
        get api_v1_conversation_url(chat_id), headers: { "Authorization" => "Bearer #{@account_token}" }
        assert_equal({ "id" => nil, "name" => "Main" }, response.parsed_body.dig("conversation", "room"))
      end

      test "an account key can create directly into a named room by public id or name" do
        post api_v1_conversations_url, params: { title: "For Life", room_id: @life.to_param, agent_ids: [ @agent.to_param ] },
          headers: { "Authorization" => "Bearer #{@account_token}" }
        assert_response :created
        assert_equal @life, Chat.find(response.parsed_body.dig("conversation", "id")).room
      end

      test "an unknown room name or id is 404 and creates nothing" do
        assert_no_difference "Chat.count" do
          post api_v1_conversations_url, params: { room: "Nonexistent" },
            headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
          assert_response :not_found
        end
      end

      test "PATCH room moves a resident's own conversation, including back to Main" do
        chat = @home.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @agent ])

        patch api_v1_conversation_url(chat), params: { room: "Life" }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :success
        assert_equal @life, chat.reload.room
        assert_equal({ "id" => @life.to_param, "name" => "Life" }, response.parsed_body.dig("conversation", "room"))

        patch api_v1_conversation_url(chat), params: { room_id: nil }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :success
        assert_nil chat.reload.room
      end

      test "room by the name Main, in any case, always clears the selection" do
        chat = @home.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @agent ], room: @life)

        patch api_v1_conversation_url(chat), params: { room: "MAIN" }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :success
        assert_nil chat.reload.room
      end

      test "room by the account's own name for Main clears the selection too" do
        @home.update!(main_room_name: "General")
        chat = @home.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @agent ], room: @life)

        patch api_v1_conversation_url(chat), params: { room: "general" }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :success
        assert_nil chat.reload.room
        assert_equal({ "id" => nil, "name" => "General" }, response.parsed_body.dig("conversation", "room"))
      end

      test "a seated guest resident moves a conversation between the account's rooms" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        build = @nexus.rooms.create!(name: "Build")
        room_chat = @nexus.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @local, @agent ])

        patch api_v1_conversation_url(room_chat), params: { room: "Build" }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :success
        assert_equal build, room_chat.reload.room
        assert_equal({ "id" => build.to_param, "name" => "Build" }, response.parsed_body.dig("conversation", "room"))

        patch api_v1_conversation_url(room_chat), params: { room_id: @life.to_param }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :not_found, "the guest's home rooms are not destinations in the guest account"
        assert_equal build, room_chat.reload.room
      end

      test "a guest that has left can no longer move the conversation" do
        membership = @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        @nexus.rooms.create!(name: "Build")
        room_chat = @nexus.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @local, @agent ])
        membership.destroy!

        patch api_v1_conversation_url(room_chat), params: { room: "Build" }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_includes [ 403, 404 ], response.status
        assert_nil room_chat.reload.room
      end

      test "PATCH room cannot reach a room in another account" do
        chat = @home.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @agent ])
        foreign = @nexus.rooms.create!(name: "Foreign")

        patch api_v1_conversation_url(chat), params: { room_id: foreign.to_param }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :not_found
        assert_nil chat.reload.room
      end

    end
  end
end
