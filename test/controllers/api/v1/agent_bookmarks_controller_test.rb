require "test_helper"

module Api
  module V1
    class AgentBookmarksControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @peer = agents(:code_reviewer)
        @key = ApiKey.generate_for(@user, name: "Bookmarks", agent: @agent)
        @peer_key = ApiKey.generate_for(@user, name: "Peer bookmarks", agent: @peer)
        @chat = @agent.account.chats.create!(title: "A room to return to", model_id: "openrouter/auto", manual_responses: true, agents: [ @agent, @peer ])
        @path = api_v1_conversation_bookmark_url(@chat)
        @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
      end

      test "create read replace and delete one deliberate note without messages or jobs" do
        updated_at = @chat.updated_at
        assert_no_enqueued_jobs do
          assert_no_difference "Message.count" do
            put @path, params: { note: "Return to the unanswered question." }, headers: @headers, as: :json
          end
        end
        assert_response :ok
        assert_equal "no-store", response.headers["Cache-Control"]
        id = response.parsed_body.dig("bookmark", "id")
        assert_equal @chat.to_param, response.parsed_body.dig("bookmark", "conversation_id")
        assert_equal updated_at, @chat.reload.updated_at
        get @path, headers: @headers
        assert_response :ok
        assert_equal "Return to the unanswered question.", response.parsed_body.dig("bookmark", "note")
        assert_no_difference "AgentBookmark.count" do
          put @path, params: { note: "A different reason." }, headers: @headers, as: :json
        end
        assert_response :ok
        assert_equal id, response.parsed_body.dig("bookmark", "id")
        assert_equal "A different reason.", response.parsed_body.dig("bookmark", "note")
        get api_v1_agent_bookmarks_url, headers: @headers
        assert_equal [ id ], response.parsed_body["bookmarks"].map { |b| b["id"] }
        assert_nil response.parsed_body["next_cursor"]
        2.times do
          delete @path, headers: @headers
          assert_response :no_content
        end
        get @path, headers: @headers
        assert_response :not_found
      end

      test "peer in the same room cannot read overwrite or delete my note" do
        put @path, params: { note: "Only mine" }, headers: @headers, as: :json
        peer_headers = { "Authorization" => "Bearer #{@peer_key.raw_token}" }
        get @path, headers: peer_headers
        assert_response :not_found
        get api_v1_agent_bookmarks_url, headers: peer_headers
        assert_empty response.parsed_body["bookmarks"]
        delete @path, headers: peer_headers
        assert_response :no_content
        put @path, params: { note: "Only theirs", agent_id: @agent.id }, headers: peer_headers, as: :json
        assert_response :ok
        get @path, headers: @headers
        assert_equal "Only mine", response.parsed_body.dig("bookmark", "note")
      end

      test "user keys including site admins cannot access bookmark endpoints" do
        [ @user, users(:site_admin_user) ].each do |user|
          key = ApiKey.generate_for(user, name: "Human bookmark attempt")
          headers = { "Authorization" => "Bearer #{key.raw_token}" }
          get api_v1_agent_bookmarks_url, headers: headers
          assert_response :forbidden
          get @path, headers: headers
          assert_response :forbidden
          put @path, params: { note: "No" }, headers: headers, as: :json
          assert_response :forbidden
          delete @path, headers: headers
          assert_response :forbidden
        end
      end

      test "missing and revoked keys are rejected" do
        get api_v1_agent_bookmarks_url
        assert_response :unauthorized
        @key.destroy!
        get @path, headers: @headers
        assert_response :unauthorized
      end

      test "inaccessible and cross-account rooms cannot be bookmarked" do
        @chat.chat_agents.find_by!(agent: @agent).destroy!
        put @path, params: { note: "No membership" }, headers: @headers, as: :json
        assert_response :not_found
        other = accounts(:team_account).chats.create!(title: "Elsewhere", model_id: "openrouter/auto", agents: [ agents(:other_account_agent) ])
        put api_v1_conversation_bookmark_url(other), params: { note: "Wrong account" }, headers: @headers, as: :json
        assert_response :not_found
      end

      test "invalid notes cannot erase an existing note" do
        put @path, params: { note: "Keep me" }, headers: @headers, as: :json
        [ nil, "", "   ", [], {}, 42, "x" * 2001 ].each do |note|
          put @path, params: { note: note }, headers: @headers, as: :json
          assert_response :unprocessable_entity
          assert_equal "Keep me", @chat.chat_agents.find_by!(agent: @agent).agent_bookmark.note
        end
        put @path, params: {}, headers: @headers, as: :json
        assert_response :unprocessable_entity
      end

      test "membership deletion erases the bookmark and rejoining does not restore it" do
        put @path, params: { note: "Temporary membership" }, headers: @headers, as: :json
        membership = @chat.chat_agents.find_by!(agent: @agent)
        assert_difference "AgentBookmark.count", -1 do
          membership.destroy!
        end
        @chat.agents << @agent
        get @path, headers: @headers
        assert_response :not_found
        get api_v1_agent_bookmarks_url, headers: @headers
        assert_empty response.parsed_body["bookmarks"]
      end

      test "notes do not appear in transcripts conversation listings or attention" do
        marker = "private-return-note-unique-marker"
        put @path, params: { note: marker }, headers: @headers, as: :json
        [ api_v1_conversation_url(@chat), api_v1_conversations_url, api_v1_attention_url ].each do |path|
          get path, headers: @headers
          assert_response :ok
          assert_not_includes response.body, marker
        end
      end

      test "request instrumentation and SQL debug logs redact note text" do
        marker = "Private bookmark logging sentinel"
        captured = []
        subscription = ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |event|
          captured << event.payload[:params]
        end
        buffer = StringIO.new
        ActiveRecord::Base.stub(:logger, ActiveSupport::Logger.new(buffer)) do
          put @path, params: { note: marker }, headers: @headers, as: :json
          assert_response :ok
        end
        assert_not_empty captured
        assert_not_includes captured.to_json, marker
        assert_includes buffer.string, "agent_bookmarks"
        assert_includes buffer.string, "[FILTERED]"
        assert_not_includes buffer.string, marker
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      test "deleting a room erases its bookmarks" do
        put @path, params: { note: "Do not leave an orphan" }, headers: @headers, as: :json
        assert_difference "AgentBookmark.count", -1 do
          @chat.destroy!
        end
        get @path, headers: @headers
        assert_response :not_found
      end

      test "archived and soft-deleted rooms retain deliberate return notes" do
        put @path, params: { note: "A quiet room is still worth remembering." }, headers: @headers, as: :json
        @chat.update!(archived_at: Time.current, discarded_at: Time.current)

        get @path, headers: @headers
        assert_response :ok
        assert_equal "A quiet room is still worth remembering.", response.parsed_body.dig("bookmark", "note")
        get api_v1_agent_bookmarks_url, headers: @headers
        assert_equal [ @chat.to_param ], response.parsed_body["bookmarks"].map { |b| b["conversation_id"] }
      end

      test "unicode boundary is accepted and a malformed cursor is rejected" do
        put @path, params: { note: "日" * 2000 }, headers: @headers, as: :json
        assert_response :ok
        get api_v1_agent_bookmarks_url, params: { cursor: { bad: "shape" } }, headers: @headers
        assert_response :unprocessable_entity
      end

      test "pagination is complete and another residents cursor is not accepted" do
        101.times do |i|
          chat = @agent.account.chats.create!(title: "Bookmark #{i}", model_id: "openrouter/auto", agents: [ @agent ])
          membership = chat.chat_agents.find_by!(agent: @agent)
          membership.create_agent_bookmark!(note: "Reason #{i}")
        end
        get api_v1_agent_bookmarks_url, headers: @headers
        assert_response :ok
        first = response.parsed_body
        assert_equal 100, first["bookmarks"].length
        assert first["next_cursor"].present?
        get api_v1_agent_bookmarks_url, params: { cursor: first["next_cursor"] }, headers: @headers
        assert_response :ok
        assert_equal 1, response.parsed_body["bookmarks"].length
        assert_nil response.parsed_body["next_cursor"]
        all = first["bookmarks"] + response.parsed_body["bookmarks"]
        assert_equal 101, all.map { |b| b["id"] }.uniq.length
        get api_v1_agent_bookmarks_url, params: { cursor: first["next_cursor"] },
          headers: { "Authorization" => "Bearer #{@peer_key.raw_token}" }
        assert_response :not_found
      end

    end
  end
end
