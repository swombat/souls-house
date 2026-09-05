require "test_helper"

module Api
  module V1
    class ConversationsCreateTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @api_key = ApiKey.generate_for(@user, name: "Test")
        @token = @api_key.raw_token
        @account = @user.accounts.first
        @agent1 = agents(:research_assistant)
        @agent2 = agents(:code_reviewer)
      end

      test "creates a simple 1-1 conversation" do
        assert_no_enqueued_jobs(only: AiResponseJob) do
          post api_v1_conversations_url,
               params: { title: "Test Chat", message: "Hello!" },
               headers: { "Authorization" => "Bearer #{@token}" }
        end
        assert_response :created

        json = JSON.parse(response.body)
        assert json["conversation"]["id"].present?
        assert_equal "Test Chat", json["conversation"]["title"]
        assert_equal false, json["conversation"]["group_chat"]
        assert_empty json["conversation"]["agents"]
      end

      test "creates a group chat with agents" do
        post api_v1_conversations_url,
             params: {
               title: "Group Discussion",
               message: "Let us discuss",
               agent_ids: [ @agent1.to_param, @agent2.to_param ]
             },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :created

        json = JSON.parse(response.body)
        assert_equal true, json["conversation"]["group_chat"]
        assert_equal 2, json["conversation"]["agents"].length

        agent_names = json["conversation"]["agents"].map { |a| a["name"] }
        assert_includes agent_names, "Research Assistant"
        assert_includes agent_names, "Code Reviewer"
      end

      test "creates conversation without initial message" do
        post api_v1_conversations_url,
             params: { title: "Empty Chat" },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :created

        json = JSON.parse(response.body)
        assert_equal "Empty Chat", json["conversation"]["title"]
      end

      test "agent-scoped key creates conversation as that agent" do
        agent_key = ApiKey.generate_for(@user, name: "Agent key", agent: @agent1)

        post api_v1_conversations_url,
             params: {
               title: "Agent Started",
               message: "I am opening this thread.",
               agent_ids: [ @agent2.to_param ]
             },
             headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }
        assert_response :created

        json = JSON.parse(response.body)
        assert_equal "Agent Started", json["conversation"]["title"]
        assert_equal true, json["conversation"]["group_chat"]

        chat = Chat.find(json["conversation"]["id"])
        assert_equal @agent1, chat.initiated_by_agent
        assert_equal [ @agent1.id, @agent2.id ].sort, chat.agent_ids.sort
        assert_equal "I am opening this thread.", chat.messages.last.content
        assert_equal @agent1, chat.messages.last.agent
        assert_equal "assistant", chat.messages.last.role
      end

      test "agent-scoped key creates conversation without initial message" do
        agent_key = ApiKey.generate_for(@user, name: "Agent key", agent: @agent1)

        post api_v1_conversations_url,
             params: { title: "Agent Empty" },
             headers: { "Authorization" => "Bearer #{agent_key.raw_token}" }
        assert_response :created

        json = JSON.parse(response.body)
        chat = Chat.find(json["conversation"]["id"])
        assert_equal "Agent Empty", json["conversation"]["title"]
        assert_equal @agent1, chat.initiated_by_agent
        assert_equal [ @agent1.id ], chat.agent_ids
        assert_empty chat.messages
      end

      test "returns 404 when agent_ids include invalid agent" do
        post api_v1_conversations_url,
             params: {
               title: "Bad Group",
               agent_ids: [ @agent1.to_param, "nonexistent" ]
             },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "returns 404 when agent_ids include inactive agent" do
        inactive = agents(:inactive_agent)
        post api_v1_conversations_url,
             params: {
               title: "Inactive Group",
               agent_ids: [ inactive.to_param ]
             },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "returns 404 when agent_ids include other account agent" do
        other_agent = agents(:other_account_agent)
        post api_v1_conversations_url,
             params: {
               title: "Cross Account",
               agent_ids: [ other_agent.to_param ]
             },
             headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "returns unauthorized without token" do
        post api_v1_conversations_url, params: { title: "No Auth" }
        assert_response :unauthorized
      end

      test "show includes group_chat and agents fields" do
        post api_v1_conversations_url,
             params: {
               title: "Show Test",
               agent_ids: [ @agent1.to_param ]
             },
             headers: { "Authorization" => "Bearer #{@token}" }
        chat_id = JSON.parse(response.body)["conversation"]["id"]

        get api_v1_conversation_url(chat_id), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        json = JSON.parse(response.body)
        assert_equal true, json["conversation"]["group_chat"]
        assert_equal 1, json["conversation"]["agents"].length
      end

      test "index includes group_chat field" do
        post api_v1_conversations_url,
             params: { title: "Index Test", agent_ids: [ @agent1.to_param ] },
             headers: { "Authorization" => "Bearer #{@token}" }

        get api_v1_conversations_url, headers: { "Authorization" => "Bearer #{@token}" }
        json = JSON.parse(response.body)

        group_chat = json["conversations"].find { |c| c["title"] == "Index Test" }
        assert group_chat
        assert_equal true, group_chat["group_chat"]
      end

    end
  end
end
