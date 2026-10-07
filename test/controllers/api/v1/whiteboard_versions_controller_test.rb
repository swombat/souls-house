require "test_helper"

module Api
  module V1
    class WhiteboardVersionsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @account = @agent.account
        @resident_token = ApiKey.generate_for(@user, name: "Resident", agent: @agent).raw_token
        @user_token = ApiKey.generate_for(@user, name: "Person", account: @account).raw_token
        @whiteboard = @account.whiteboards.create!(name: "Build board", content: "First text", summary: "Board")
        @first_revision = @whiteboard.revision
      end

      test "a resident's edit is credited to the resident, not the key's owner" do
        edit(@resident_token, "Second text")

        @whiteboard.reload
        assert_equal @agent, @whiteboard.last_edited_by
        assert_equal @agent.name, @whiteboard.editor_name
        assert_equal "Agent:#{@agent.id}", @whiteboard.versions.last.whodunnit
      end

      test "a person's key edit is credited to the person" do
        edit(@user_token, "Second text")

        @whiteboard.reload
        assert_equal @user, @whiteboard.last_edited_by
        assert_equal "User:#{@user.id}", @whiteboard.versions.last.whodunnit
      end

      test "lists past states newest first, each with who replaced it" do
        edit(@user_token, "Second text")
        edit(@resident_token, "Third text")

        get api_v1_whiteboard_versions_url(@whiteboard), headers: auth(@resident_token)
        assert_response :success

        json = JSON.parse(response.body)
        assert_equal @whiteboard.to_param, json["whiteboard"]["id"]
        assert_equal @first_revision + 2, json["whiteboard"]["revision"]

        versions = json["versions"]
        assert_equal [ @first_revision + 1, @first_revision ], versions.map { |v| v["revision"] }
        assert_equal [ @agent.name, @user.full_name.presence || @user.email_address.split("@").first ],
          versions.map { |v| v["replaced_by"] }
        assert_equal "Second text".length, versions.first["content_length"]
        assert_equal %w[edited edited], versions.map { |v| v["event"] }
        assert_not versions.first.key?("content"), "the list stays light; read one version for its text"
      end

      test "reads one past version in full" do
        edit(@user_token, "Second text")
        version = @whiteboard.past_versions.first

        get api_v1_whiteboard_version_url(@whiteboard, version), headers: auth(@resident_token)
        assert_response :success

        json = JSON.parse(response.body)["version"]
        assert_equal version.to_param, json["id"]
        assert_equal "First text", json["content"]
        assert_equal @first_revision, json["revision"]
      end

      test "a version of another note is not found through this one" do
        other = @account.whiteboards.create!(name: "Other", content: "a")
        other.update!(content: "b")

        get api_v1_whiteboard_version_url(@whiteboard, other.past_versions.first), headers: auth(@resident_token)
        assert_response :not_found
      end

      test "a key from another account cannot read the history" do
        elsewhere = accounts(:confirmed_user_account)
        assert_not_equal @account, elsewhere
        token = ApiKey.generate_for(@user, name: "Elsewhere", account: elsewhere).raw_token

        get api_v1_whiteboard_versions_url(@whiteboard), headers: auth(token)
        assert_response :not_found
      end

      test "requires a key" do
        get api_v1_whiteboard_versions_url(@whiteboard)
        assert_response :unauthorized
      end

      private

      def auth(token)
        { "Authorization" => "Bearer #{token}" }
      end

      def edit(token, content)
        @whiteboard.reload
        patch api_v1_whiteboard_url(@whiteboard),
          params: { content: content, lock_version: @whiteboard.lock_version },
          headers: auth(token)
        assert_response :success
      end

    end
  end
end
