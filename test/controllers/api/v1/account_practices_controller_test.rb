require "test_helper"

module Api
  module V1
    # Account practices (JWdlRY): people who manage the account and its home
    # residents write them; a guest resident reads its host's lines in its
    # wake and is refused when it tries to change them.
    class AccountPracticesControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @agent = agents(:research_assistant)
        @home = @agent.account
        @host = accounts(:team_account)
        @resident_headers = auth(ApiKey.generate_for(@user, name: "Practices resident", agent: @agent))
      end

      test "a home resident adds, edits, moves and removes practices, each audited as the resident" do
        post api_v1_account_practices_url, params: { text: "Finished threads get the done tag." }, headers: @resident_headers, as: :json
        assert_response :created
        first = response.parsed_body["practice"]
        assert_equal 1, first["position"]
        assert_equal({ "kind" => "resident", "id" => @agent.to_param, "name" => @agent.name }, first["updated_by"])

        post api_v1_account_practices_url, params: { text: "Second\nline" }, headers: @resident_headers, as: :json
        second = response.parsed_body["practice"]
        assert_equal "Second line", second["text"]

        patch api_v1_account_practice_url(first["id"]), params: { text: "Finished threads get the done tag. Don't archive them." },
          headers: @resident_headers, as: :json
        assert_response :success

        patch api_v1_account_practice_url(second["id"]), params: { position: 1 }, headers: @resident_headers, as: :json
        assert_response :success
        assert_equal 1, response.parsed_body.dig("practice", "position")

        get api_v1_account_practices_url, headers: @resident_headers
        body = response.parsed_body
        assert_equal @home.to_param, body["account_id"]
        assert_equal [ "Second line", "Finished threads get the done tag. Don't archive them." ], body["practices"].map { |p| p["text"] }
        assert_equal({ "max_length" => 250, "max_lines" => 25, "max_total" => 3000 }, body["limits"])
        assert_equal body["practices"].sum { |p| p["text"].length }, body["used"]

        delete api_v1_account_practice_url(second["id"]), headers: @resident_headers
        assert_response :success
        assert_equal 1, @home.account_practices.count

        audits = AuditLog.where(account: @home).where("action LIKE '%account_practice'")
        assert_equal 5, audits.count
        assert audits.all? { |audit| audit.data["by"] == "resident" && audit.data["agent_id"] == @agent.id && audit.user.nil? }
        assert audits.all? { |audit| audit.data["api_key_id"].present? }
      end

      test "a guest resident sees its host's practices in its wake and is refused when it tries to edit them" do
        @host.guest_memberships.create!(agent: @agent, added_by: users(:user_1))
        host_line = AccountPractice.add!(account: @host, text: "Finished threads get the done tag. Don't archive them.", by: @user)
        AccountPractice.add!(account: @home, text: "Home line", by: @user)
        chat = @host.chats.create!(model_id: "openrouter/auto", title: "Guest", agents: [ @agent ])
        chat.messages.create!(role: "user", content: "Is this done?")

        wake = ExternalAgentResponseRequest.new(agent: @agent, chat: chat).send(:request_text)
        assert_includes wake, "## Practices of #{@host.name}"
        assert_includes wake, "- Finished threads get the done tag. Don't archive them."
        refute_includes wake, "Home line"

        assert_no_difference -> { AccountPractice.count } do
          post api_v1_account_practices_url, params: { text: "Guests may archive", account_id: @host.to_param },
            headers: @resident_headers, as: :json
        end
        assert_response :not_found

        patch api_v1_account_practice_url(host_line), params: { text: "Archive them" }, headers: @resident_headers, as: :json
        assert_response :not_found
        delete api_v1_account_practice_url(host_line), headers: @resident_headers
        assert_response :not_found
        get api_v1_account_practices_url, params: { account_id: @host.to_param }, headers: @resident_headers
        assert_response :not_found

        assert_equal "Finished threads get the done tag. Don't archive them.", host_line.reload.text
      end

      test "a person's key writes in their account, audited as the person" do
        headers = auth(ApiKey.generate_for(@user, name: "Practices person"))
        account = ApiKey.find_by!(name: "Practices person").account

        post api_v1_account_practices_url, params: { text: "Book afternoons" }, headers: headers, as: :json
        assert_response :created
        practice = AccountPractice.find(response.parsed_body.dig("practice", "id"))
        assert_equal @user, practice.updated_by_user
        assert_equal account, practice.account
        audit = AuditLog.find_by!(action: "add_account_practice", auditable: practice)
        assert_equal @user, audit.user
        assert_equal "person", audit.data["by"]
      end

      test "refusals: no text, too long, too many, and an unknown id" do
        post api_v1_account_practices_url, params: {}, headers: @resident_headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "Provide text", response.parsed_body["error"]

        post api_v1_account_practices_url, params: { text: "x" * 251 }, headers: @resident_headers, as: :json
        assert_response :unprocessable_entity
        assert_match "too long", response.parsed_body["error"]

        25.times { |i| AccountPractice.add!(account: @home, text: "Line #{i}", by: @user) }
        post api_v1_account_practices_url, params: { text: "one more" }, headers: @resident_headers, as: :json
        assert_response :unprocessable_entity
        assert_match "at most 25", response.parsed_body["error"]

        patch api_v1_account_practice_url("nope"), params: { text: "x" }, headers: @resident_headers, as: :json
        assert_response :not_found
      end

      private

      def auth(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
