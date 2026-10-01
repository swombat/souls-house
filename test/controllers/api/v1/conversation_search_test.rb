require "test_helper"

module Api
  module V1
    class ConversationSearchTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @account = @agent.account
        @key = ApiKey.generate_for(@user, name: "Search", agent: @agent)
        @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
        @chat = room(@account, [ @agent ])
      end

      test "finds an exact past line across rooms without returning whole messages" do
        other = room(@account, [ @agent ])
        content = ("Before. " * 100) + "I did not agree to Niaux first" + (" After." * 100)
        message = other.messages.create!(role: "assistant", agent: @agent, content: content)
        search("did not agree to Niaux first")
        assert_response :ok
        assert_equal "no-store", response.headers["Cache-Control"]
        result = response.parsed_body["messages"].sole
        assert_equal other.to_param, result["conversation_id"]
        assert_equal message.to_param, result["message_id"]
        assert_equal message.created_at.iso8601, result["authored_at"]
        assert_equal @agent.name, result["author"]
        assert_equal api_v1_conversation_path(other), result["detail_path"]
        assert_includes result["snippet"], "did not agree to Niaux first"
        assert_operator result["snippet"].length, :<=, 400
        assert_equal content[result["snippet_offset"], 400], result["snippet"]
        assert_not result.key?("content")
        assert_nil response.parsed_body["next_cursor"]
      end

      test "search is literal case sensitive and preserves whitespace and unicode" do
        text = "A  100%_\\ marker 🌱"
        message = @chat.messages.create!(role: "user", user: @user, content: text)
        [ "100%_\\", "A  ", "🌱" ].each do |query|
          search(query)
          assert_response :ok
          assert_equal [ message.to_param ], result_ids
        end
        [ "a  ", "A   ", "' OR 1=1 --" ].each do |query|
          search(query)
          assert_empty result_ids
        end
      end

      test "agent cannot search nonmember or other account rooms" do
        hidden = room(@account, [ agents(:code_reviewer) ])
        foreign = room(accounts(:team_account), [ agents(:other_account_agent) ])
        [ hidden, foreign ].each { |chat| chat.messages.create!(role: "user", content: "private needle", user: @user) }
        search("needle")
        assert_response :ok
        assert_empty result_ids
      end

      test "empty results guide a shorter fragment without claiming an exchange never happened" do
        message = @chat.messages.create!(role: "user", user: @user, content: "the words between pain")
        search("the words of pain")
        assert_response :ok
        assert_empty result_ids
        assert_nil response.parsed_body["next_cursor"]
        assert_equal "No literal match on this page. Try a shorter distinctive fragment or check capitalization; an empty result does not mean an exchange never happened.",
          response.parsed_body["guidance"]
        assert_not_includes response.body, "the words of pain"

        search("pain")
        assert_equal [ message.to_param ], result_ids
        assert_not response.parsed_body.key?("guidance")
      end

      test "account key remains confined to its account" do
        local = room(@account, [])
        local_message = local.messages.create!(role: "user", content: "needle", user: @user)
        foreign = room(accounts(:team_account), [])
        foreign.messages.create!(role: "user", content: "needle", user: @user)
        key = ApiKey.generate_for(@user, name: "Account search", account: @account)
        @headers = { "Authorization" => "Bearer #{key.raw_token}" }
        search("needle")
        assert_response :ok
        assert_equal [ local_message.to_param ], result_ids
      end

      test "excludes archived discarded tool system and progress messages" do
        archived = room(@account, [ @agent ])
        discarded = room(@account, [ @agent ])
        [ archived, discarded ].each { |chat| chat.messages.create!(role: "user", content: "needle", user: @user) }
        archived.archive!
        discarded.discard!
        %w[system tool].each { |role| @chat.messages.create!(role: role, content: "needle #{role}") }
        progress = @chat.messages.create!(role: "assistant", content: "needle progress", agent: @agent)
        progress.update_column(:progress_message, true)
        search("needle")
        assert_response :ok
        assert_empty result_ids
      end

      test "pages by descending message id without duplicates even when timestamps tie" do
        messages = 51.times.map do |i|
          @chat.messages.create!(role: "assistant", content: "needle #{i}", created_at: Time.utc(2026, 1, 1))
        end
        search("needle")
        assert_response :ok
        assert_equal messages.reverse.first(50).map(&:to_param), result_ids
        cursor = response.parsed_body["next_cursor"]
        assert_equal messages[1].to_param, cursor
        search("needle", cursor: cursor)
        assert_response :ok
        assert_equal [ messages.first.to_param ], result_ids
        assert_nil response.parsed_body["next_cursor"]
      end

      test "discarding a message removes it from results and invalidates its cursor" do
        message = @chat.messages.create!(role: "user", content: "discard needle", user: @user)
        search("discard needle")
        assert_equal [ message.to_param ], result_ids
        message.discard!
        search("discard needle")
        assert_response :ok
        assert_empty result_ids
        search("discard needle", cursor: message.to_param)
        assert_response :not_found
      end

      test "cursor must remain a matching accessible message" do
        hidden = room(@account, [])
        inaccessible = hidden.messages.create!(role: "user", content: "needle", user: @user)
        nonmatching = @chat.messages.create!(role: "user", content: "different", user: @user)
        [ inaccessible.to_param, nonmatching.to_param, "invalid" ].each do |cursor|
          search("needle", cursor: cursor)
          assert_response :not_found
        end
      end

      test "removing membership removes search access immediately" do
        message = @chat.messages.create!(role: "assistant", content: "needle")
        search("needle")
        assert_equal [ message.to_param ], result_ids
        @chat.chat_agents.where(agent: @agent).delete_all
        search("needle")
        assert_empty result_ids
        search("needle", cursor: message.to_param)
        assert_response :not_found
      end

      test "rejects missing blank oversized and structured queries" do
        [ nil, "", "  ", "x" * 201, "\0", [ "needle" ], { text: "needle" } ].each do |query|
          search(query)
          assert_response :unprocessable_entity
        end
      end

      test "requires a valid active credential" do
        get search_api_v1_conversations_url, params: { query: "needle" }
        assert_response :unauthorized
        @key.destroy!
        search("needle")
        assert_response :unauthorized
      end

      test "rejects structured cursors" do
        [ [ "cursor" ], { id: "cursor" } ].each do |cursor|
          search("needle", cursor: cursor)
          assert_response :unprocessable_entity
        end
      end

      test "query text is filtered in SQL logs" do
        output = StringIO.new
        previous_logger = ActiveRecord::Base.logger
        ActiveRecord::Base.logger = ActiveSupport::Logger.new(output)
        search("private-search-sentinel")
        assert_response :ok
        assert_includes output.string, "strpos"
        assert_includes output.string, "[FILTERED]"
        assert_not_includes output.string, "private-search-sentinel"
      ensure
        ActiveRecord::Base.logger = previous_logger
      end

      private

      def room(account, agents)
        account.chats.create!(model_id: "openrouter/auto", title: "Search room", manual_responses: agents.any?, agents: agents)
      end

      def search(query, **params)
        get search_api_v1_conversations_url, params: params.merge(query: query), headers: @headers
      end

      def result_ids
        response.parsed_body.fetch("messages").map { |message| message.fetch("message_id") }
      end

    end
  end
end
