require "test_helper"

module Api
  module V1
    class WhiteboardsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @api_key = ApiKey.generate_for(@user, name: "Test")
        @token = @api_key.raw_token
        @account = @user.personal_account
        @whiteboard = @account.whiteboards.create!(name: "Test Board", content: "Initial content", summary: "A test board")
      end

      test "returns unauthorized without token" do
        get api_v1_whiteboards_url
        assert_response :unauthorized
      end

      test "lists whiteboards with valid token" do
        get api_v1_whiteboards_url, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        json = JSON.parse(response.body)
        assert json["whiteboards"].is_a?(Array)
        assert json["whiteboards"].length >= 1
      end

      test "lists only active whiteboards" do
        deleted_board = @account.whiteboards.create!(name: "Deleted Board", content: "Content")
        deleted_board.soft_delete!

        get api_v1_whiteboards_url, headers: { "Authorization" => "Bearer #{@token}" }
        json = JSON.parse(response.body)

        names = json["whiteboards"].map { |w| w["name"] }
        assert_includes names, "Test Board"
        assert_not_includes names, "Deleted Board"
      end

      test "shows whiteboard details" do
        get api_v1_whiteboard_url(@whiteboard), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        json = JSON.parse(response.body)
        assert_equal @whiteboard.to_param, json["whiteboard"]["id"]
        assert_equal "Test Board", json["whiteboard"]["name"]
        assert_equal "Initial content", json["whiteboard"]["content"]
        assert_equal 0, json["whiteboard"]["lock_version"]
      end

      test "returns 404 for unknown whiteboard" do
        get api_v1_whiteboard_url("nonexistent"), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "returns 404 for deleted whiteboard" do
        @whiteboard.soft_delete!

        get api_v1_whiteboard_url(@whiteboard), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "updates whiteboard content" do
        patch api_v1_whiteboard_url(@whiteboard),
              params: { content: "Updated content", lock_version: 0 },
              headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        json = JSON.parse(response.body)
        assert json["whiteboard"]["lock_version"] > 0

        @whiteboard.reload
        assert_equal "Updated content", @whiteboard.content
      end

      test "updates whiteboard metadata without clearing content" do
        patch api_v1_whiteboard_url(@whiteboard),
              params: { name: "Renamed Board", summary: "Updated summary", lock_version: 0 },
              headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        @whiteboard.reload
        assert_equal "Renamed Board", @whiteboard.name
        assert_equal "Updated summary", @whiteboard.summary
        assert_equal "Initial content", @whiteboard.content
      end

      test "update requires lock_version" do
        patch api_v1_whiteboard_url(@whiteboard),
              params: { content: "Updated content" },
              headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity

        json = JSON.parse(response.body)
        assert_equal "lock_version must be an integer", json["error"]
        assert_equal "Initial content", @whiteboard.reload.content
      end

      test "update rejects null lock_version" do
        patch api_v1_whiteboard_url(@whiteboard),
              params: { content: "Updated content", lock_version: nil },
              headers: { "Authorization" => "Bearer #{@token}" },
              as: :json
        assert_response :unprocessable_entity

        json = JSON.parse(response.body)
        assert_equal "lock_version must be an integer", json["error"]
        assert_equal "Initial content", @whiteboard.reload.content
      end

      test "update rejects unsupported payload without clearing content" do
        patch api_v1_whiteboard_url(@whiteboard),
              params: { whiteboard: { content: "Nested content" }, lock_version: 0 },
              headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :unprocessable_entity

        json = JSON.parse(response.body)
        assert_equal "Provide name, summary, or content", json["error"]
        assert_equal "Initial content", @whiteboard.reload.content
      end

      test "update returns conflict on stale lock_version" do
        # Update with correct lock_version first
        patch api_v1_whiteboard_url(@whiteboard),
              params: { content: "First update", lock_version: 0 },
              headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        # Try to update with stale lock_version
        patch api_v1_whiteboard_url(@whiteboard),
              params: { content: "Second update", lock_version: 0 },
              headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :conflict

        json = JSON.parse(response.body)
        assert_equal "Whiteboard was modified by another user", json["error"]
      end

      %w[content summary name].each do |field|
        test "update rejects null #{field} without changing the board" do
          before = @whiteboard.reload.attributes

          patch api_v1_whiteboard_url(@whiteboard),
                params: { field => nil, "lock_version" => @whiteboard.lock_version },
                headers: { "Authorization" => "Bearer #{@token}" },
                as: :json

          assert_response :unprocessable_entity
          assert_equal "Provided name, summary, and content must not be null", response.parsed_body["error"]
          assert_equal before, @whiteboard.reload.attributes
        end

        test "update rejects null #{field} alongside a valid edit atomically" do
          before = @whiteboard.reload.attributes
          valid_field = field == "name" ? "content" : "name"

          patch api_v1_whiteboard_url(@whiteboard),
                params: { field => nil, valid_field => "Changed", "lock_version" => @whiteboard.lock_version },
                headers: { "Authorization" => "Bearer #{@token}" },
                as: :json

          assert_response :unprocessable_entity
          assert_equal before, @whiteboard.reload.attributes
        end
      end

      %w[content summary].each do |field|
        test "update allows an explicit empty string to clear #{field}" do
          before = @whiteboard.attributes.slice("name", "content", "summary")
          version = @whiteboard.lock_version

          patch api_v1_whiteboard_url(@whiteboard),
                params: { field => "", "lock_version" => version },
                headers: { "Authorization" => "Bearer #{@token}" },
                as: :json

          assert_response :success
          assert_equal before.merge(field => ""), @whiteboard.reload.attributes.slice("name", "content", "summary")
          assert_equal version + 1, @whiteboard.lock_version
        end
      end

      test "update still rejects an empty name without changing the board" do
        before = @whiteboard.reload.attributes

        patch api_v1_whiteboard_url(@whiteboard),
              params: { name: "", lock_version: @whiteboard.lock_version },
              headers: { "Authorization" => "Bearer #{@token}" },
              as: :json

        assert_response :unprocessable_entity
        assert_equal before, @whiteboard.reload.attributes
      end

      test "update sets last_edited_by to API user" do
        patch api_v1_whiteboard_url(@whiteboard),
              params: { content: "Updated content", lock_version: 0 },
              headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        @whiteboard.reload
        assert_equal @user, @whiteboard.last_edited_by
      end

      test "cannot access other user whiteboards" do
        other_user = users(:existing_user)
        other_account = other_user.personal_account
        other_board = other_account.whiteboards.create!(name: "Other Board", content: "Content")

        get api_v1_whiteboard_url(other_board), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      # Create whiteboard tests

      test "creates whiteboard with valid params" do
        assert_difference -> { @account.whiteboards.count }, 1 do
          post api_v1_whiteboards_url,
               params: { name: "New Board", content: "Some content", summary: "A summary" },
               headers: { "Authorization" => "Bearer #{@token}" }
        end

        assert_response :created

        json = JSON.parse(response.body)
        assert_equal "New Board", json["whiteboard"]["name"]
        assert_equal 0, json["whiteboard"]["lock_version"]
        assert json["whiteboard"]["id"].present?
      end

      test "creates whiteboard with only name" do
        post api_v1_whiteboards_url,
             params: { name: "Minimal Board" },
             headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :created

        whiteboard = @account.whiteboards.find_by(name: "Minimal Board")
        assert whiteboard.present?
        assert_nil whiteboard.content
      end

      test "create sets last_edited_by to API user" do
        post api_v1_whiteboards_url,
             params: { name: "User Board" },
             headers: { "Authorization" => "Bearer #{@token}" }

        whiteboard = @account.whiteboards.find_by(name: "User Board")
        assert_equal @user, whiteboard.last_edited_by
      end

      test "create fails without name" do
        post api_v1_whiteboards_url,
             params: { content: "Some content" },
             headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :unprocessable_entity

        json = JSON.parse(response.body)
        assert json["error"].include?("Name")
      end

      test "create fails with duplicate name" do
        post api_v1_whiteboards_url,
             params: { name: "Test Board" },
             headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :unprocessable_entity

        json = JSON.parse(response.body)
        assert json["error"].include?("taken")
      end

    end
  end
end
