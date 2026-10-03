require "test_helper"

module Api
  module V1
    class StonesControllerTest < ActionDispatch::IntegrationTest

      HTML = "<!doctype html><html><head><title>Public stone</title></head><body><p>Original</p></body></html>"

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @peer = agents(:code_reviewer)
        @account = @agent.account
        @chat = @account.chats.create!(title: "Private conversation title", model_id: "openrouter/auto", agents: [ @agent, @peer ])
        @key = ApiKey.generate_for(@user, name: "Stones", account: @account)
        @agent_key = ApiKey.generate_for(@user, name: "Resident stones", agent: @agent)
        @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
        @agent_headers = { "Authorization" => "Bearer #{@agent_key.raw_token}" }
        @path = "/api/v1/conversations/#{@chat.to_param}/stones"
      end

      test "all stone operations require authentication" do
        get @path
        assert_response :unauthorized
        post @path, params: valid_params, as: :json
        assert_response :unauthorized
      end

      test "publishing creates a standalone attributed record without messages or response jobs" do
        assert_no_difference "Message.count" do
          assert_difference [ "Stone.count", "StoneRevision.count" ], 1 do
            post @path, params: valid_params.merge(user_id: users(:existing_user).id, agent_id: @agent.id), headers: @headers, as: :json
          end
        end
        assert_response :created
        stone = @chat.stones.last
        assert_equal @user, stone.latest_revision.user
        assert_nil stone.latest_revision.agent_id
        assert_equal HTML, stone.latest_revision.html_document
        data = response.parsed_body.fetch("stone")
        assert_equal "/stones/#{stone.public_token}", data["public_url"]
        assert_equal "/stones/#{stone.public_token}/revisions/1", data.dig("latest_revision", "public_url")
        assert_equal "not_requested", data.dig("latest_revision", "preview_status")
        assert_not_includes response.body, @chat.title
        assert_not_includes response.body, stone.latest_revision.html.blob.signed_id
        assert_equal "no-store", response.headers["Cache-Control"]
      end

      test "resident author is taken from the principal and requires participation" do
        post @path, params: valid_params.merge(user_id: @user.id, agent_id: @peer.id), headers: @agent_headers, as: :json
        assert_response :created
        revision = @chat.stones.last.latest_revision
        assert_equal @agent, revision.agent
        assert_nil revision.user_id
        @chat.chat_agents.find_by!(agent: @agent).destroy!
        get @path, headers: @agent_headers
        assert_response :not_found
        post @path, params: valid_params, headers: @agent_headers, as: :json
        assert_response :not_found
      end

      test "account keys and resident membership cannot cross account boundaries" do
        other = accounts(:team_account).chats.create!(title: "Elsewhere", model_id: "openrouter/auto", agents: [ agents(:other_account_agent) ])
        other.agents << @agent
        other_path = "/api/v1/conversations/#{other.to_param}/stones"
        [ @headers, @agent_headers ].each do |headers|
          get other_path, headers: headers
          assert_response :not_found
          post other_path, params: valid_params, headers: headers, as: :json
          assert_response :not_found
        end
      end

      test "publication requires explicit true and rejects invalid payloads atomically" do
        [ false, nil, "true", "false", 1 ].each do |ack|
          assert_no_difference [ "Stone.count", "StoneRevision.count" ] do
            post @path, params: valid_params.merge(public: ack), headers: @headers, as: :json
          end
          assert_response :unprocessable_entity
        end
        [ { title: "" }, { html: {} }, { html: nil }, { html: "x" * (Stone::MAX_HTML_BYTES + 1) },
          { html: '<!doctype html><html><body><script src="https://example.com/x.js"></script></body></html>' } ].each do |params|
          assert_no_difference [ "Stone.count", "StoneRevision.count" ] do
            post @path, params: valid_params.merge(params), headers: @headers, as: :json
          end
          assert_response :unprocessable_entity
        end
      end

      test "accepts one HTML upload and rejects multiple files or HTML plus a file" do
        file = Tempfile.new([ "stone", ".html" ])
        file.write(HTML)
        file.rewind
        upload = Rack::Test::UploadedFile.new(file.path, "text/html")
        post @path, params: { title: "Upload", public: "true", file: upload }, headers: @headers
        assert_response :created
        assert_equal HTML, @chat.stones.last.latest_revision.html_document

        [ { file: [ upload ] }, { file: upload, html: HTML } ].each do |params|
          post @path, params: { title: "Rejected", public: "true" }.merge(params), headers: @headers
          assert_response :unprocessable_entity
        end
      ensure
        file&.close!
      end

      test "authenticated listing and show return only this conversation's records" do
        post @path, params: valid_params, headers: @headers, as: :json
        id = response.parsed_body.dig("stone", "id")
        get @path, headers: @headers
        assert_response :ok
        assert_equal [ id ], response.parsed_body["stones"].map { |stone| stone["id"] }
        get "#{@path}/#{id}", headers: @headers
        assert_response :ok
        other_chat = @account.chats.create!(title: "Another room", model_id: "openrouter/auto", agents: [ @agent ])
        get "/api/v1/conversations/#{other_chat.to_param}/stones/#{id}", headers: @headers
        assert_response :not_found
      end

      test "withdrawal keeps a tombstone and discarded conversations are not accessible" do
        post @path, params: valid_params, headers: @headers, as: :json
        id = response.parsed_body.dig("stone", "id")
        delete "#{@path}/#{id}", headers: @headers
        assert_response :no_content
        assert @chat.stones.last.withdrawn?
        get "#{@path}/#{id}", headers: @headers
        assert_response :ok
        assert response.parsed_body.dig("stone", "withdrawn_at").present?
        @chat.discard!
        get "#{@path}/#{id}", headers: @headers
        assert_response :not_found
        get @path, headers: @agent_headers
        assert_response :not_found
      end

      private

      def valid_params
        { title: "Public stone", html: HTML, public: true }
      end

    end
  end
end
