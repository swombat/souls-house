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

    end
  end
end
