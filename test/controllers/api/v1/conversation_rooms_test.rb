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

      test "a resident key at home with an explicit room public id lands the conversation there" do
        post api_v1_conversations_url, params: { room: @life.to_param },
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

      test "a guest resident's create ignores room and the JSON carries no room key" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        guest_default = @nexus.rooms.create!(name: "Guest Room")
        @nexus.update!(resident_room: guest_default)

        post api_v1_conversations_url,
          params: { account_id: @nexus.to_param, room: "Anything", agent_ids: [ @local.to_param ] },
          headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
        assert_response :created

        json = response.parsed_body.fetch("conversation")
        chat = Chat.find(json["id"])
        assert_equal guest_default, chat.room, "the guest's room param is ignored; the account's resident default wins"
        assert_not json.key?("room")
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
        post api_v1_conversations_url, params: { title: "For Life", room: @life.to_param, agent_ids: [ @agent.to_param ] },
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

        patch api_v1_conversation_url(chat), params: { room: nil }, as: :json,
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

      test "a guest resident cannot move a conversation between rooms" do
        @nexus.guest_memberships.create!(agent: @agent, added_by: @daniel)
        room_chat = @nexus.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @local, @agent ])

        patch api_v1_conversation_url(room_chat), params: { room: "Anything" }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :forbidden
        assert_nil room_chat.reload.room
      end

      test "PATCH room cannot reach a room in another account" do
        chat = @home.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @agent ])
        foreign = @nexus.rooms.create!(name: "Foreign")

        patch api_v1_conversation_url(chat), params: { room: foreign.to_param }, as: :json,
          headers: { "Authorization" => "Bearer #{@agent_token}" }
        assert_response :not_found
        assert_nil chat.reload.room
      end

    end
  end
end
