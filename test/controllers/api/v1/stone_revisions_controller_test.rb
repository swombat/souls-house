require "test_helper"

module Api
  module V1
    class StoneRevisionsControllerTest < ActionDispatch::IntegrationTest

      HTML = "<!doctype html><html><body><p>Original revision</p></body></html>"

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @chat = @agent.account.chats.create!(title: "Revision room", model_id: "openrouter/auto", agents: [ @agent ])
        @key = ApiKey.generate_for(@user, name: "Revisions", account: @chat.account)
        @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
        @stone = Stone.publish!(chat: @chat, title: "Original", html: HTML, author: @agent, public: true)
        @revision = @stone.latest_revision
        @path = "/api/v1/conversations/#{@chat.to_param}/stones/#{@stone.to_param}/revisions"
      end

      test "show requires authority and returns the requested original document as JSON not active HTML" do
        get "#{@path}/#{@revision.to_param}"
        assert_response :unauthorized
        get "#{@path}/#{@revision.to_param}", headers: @headers
        assert_response :ok
        assert_equal "application/json", response.media_type
        assert_equal HTML, response.parsed_body.dig("revision", "html")
        assert_equal @revision.to_param, response.parsed_body.dig("revision", "id")
        assert_not_includes response.body, @chat.title
      end

      test "revision creates a new attributed immutable version and stale bases conflict" do
        assert_difference "StoneRevision.count", 1 do
          post @path, params: revision_params, headers: @headers, as: :json
        end
        assert_response :created
        second = @stone.latest_revision
        assert_equal 2, second.number
        assert_equal @user, second.user
        assert_equal HTML, @revision.html_document
        assert_no_difference "StoneRevision.count" do
          post @path, params: revision_params, headers: @headers, as: :json
        end
        assert_response :conflict
        get @path, headers: @headers
        assert_response :ok
        assert_equal [ 2, 1 ], response.parsed_body["revisions"].map { |revision| revision["number"] }
      end

      test "revision requires explicit public acknowledgement and a current base" do
        [ { public: nil }, { public: false }, { public: "true" }, { base_revision_id: nil } ].each do |attributes|
          assert_no_difference "StoneRevision.count" do
            post @path, params: revision_params.merge(attributes), headers: @headers, as: :json
          end
          assert_response attributes.key?(:base_revision_id) ? :conflict : :unprocessable_entity
        end
      end

      test "withdrawal blocks revision delivery and further publication immediately" do
        @stone.withdraw!
        get "#{@path}/#{@revision.to_param}", headers: @headers
        assert_response :gone
        post @path, params: revision_params, headers: @headers, as: :json
        assert_response :gone
        get @path, headers: @headers
        assert_response :ok
        assert_equal [ @revision.to_param ], response.parsed_body["revisions"].map { |revision| revision["id"] }
        assert_not_includes response.body, HTML
      end

      test "wrong conversation account or missing resident membership cannot access revisions" do
        other = @agent.account.chats.create!(title: "Wrong room", model_id: "openrouter/auto", agents: [ @agent ])
        get "/api/v1/conversations/#{other.to_param}/stones/#{@stone.to_param}/revisions/#{@revision.to_param}", headers: @headers
        assert_response :not_found
        other_key = ApiKey.generate_for(users(:existing_user), name: "Elsewhere", account: accounts(:team_account))
        get "#{@path}/#{@revision.to_param}", headers: { "Authorization" => "Bearer #{other_key.raw_token}" }
        assert_response :not_found
        agent_key = ApiKey.generate_for(@user, name: "Removed participant", agent: @agent)
        @chat.chat_agents.find_by!(agent: @agent).destroy!
        get "#{@path}/#{@revision.to_param}", headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }
        assert_response :not_found
      end

      private

      def revision_params
        { title: "Second", html: HTML.sub("Original", "Second"), public: true, base_revision_id: @revision.to_param }
      end

    end
  end
end
