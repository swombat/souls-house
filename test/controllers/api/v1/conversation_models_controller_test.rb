require "test_helper"

module Api
  module V1
    class ConversationModelsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @account = @user.accounts.first
        @agent = agents(:research_assistant)
        @other = agents(:code_reviewer)
        @agent.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])
        @agent_token = ApiKey.generate_for(@user, name: "Agent key", agent: @agent).raw_token
        @account_token = ApiKey.generate_for(@user, name: "Account key").raw_token
        @chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
        @chat.agent_ids = [ @agent.id, @other.id ]
        @chat.save!
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      def seat = ChatAgent.find_by!(chat: @chat, agent: @agent)

      test "resident reads its own selection" do
        get api_v1_conversation_model_url(@chat), headers: auth(@agent_token)

        assert_response :success
        json = JSON.parse(response.body)["model_selection"]
        assert_equal "anthropic/claude-opus-5.5", json["model_id"]
        assert_equal [ "anthropic/claude-opus-5.5", "anthropic/claude-fable-5.1" ], json["choices"].map { |c| c["model_id"] }
      end

      test "resident cannot switch itself without the account's permission" do
        post api_v1_conversation_model_url(@chat), params: { model_id: "anthropic/claude-fable-5.1" }, as: :json, headers: auth(@agent_token)

        assert_response :forbidden
        assert_nil seat.model_id
      end

      test "permitted resident switches its own seat, which does not start a turn" do
        @agent.update!(resident_may_switch_model: true)

        assert_no_enqueued_jobs do
          post api_v1_conversation_model_url(@chat), params: { model_id: "anthropic/claude-fable-5.1" }, as: :json, headers: auth(@agent_token)
        end

        assert_response :success
        assert_equal "anthropic/claude-fable-5.1", seat.model_id
        assert_match(/Research Assistant \(the resident\)/, @chat.messages.where(role: "system").last.content)
        assert_nil ChatAgent.find_by!(chat: @chat, agent: @other).model_id
      end

      test "resident token ignores agent_id and cannot switch another resident" do
        @agent.update!(resident_may_switch_model: true)
        @other.update!(model_id: "anthropic/claude-opus-5.5", switchable_model_ids: [ "anthropic/claude-fable-5.1" ])

        post api_v1_conversation_model_url(@chat),
          params: { model_id: "anthropic/claude-fable-5.1", agent_id: @other.to_param }, as: :json, headers: auth(@agent_token)

        assert_response :success
        assert_nil ChatAgent.find_by!(chat: @chat, agent: @other).model_id
        assert_equal "anthropic/claude-fable-5.1", seat.model_id
      end

      test "a model off the list is refused" do
        @agent.update!(resident_may_switch_model: true)
        post api_v1_conversation_model_url(@chat), params: { model_id: "anthropic/claude-haiku-5.5" }, as: :json, headers: auth(@agent_token)

        assert_response :unprocessable_entity
        assert_nil seat.model_id
      end

      test "account key names the resident" do
        post api_v1_conversation_model_url(@chat),
          params: { model_id: "anthropic/claude-fable-5.1", agent_id: @agent.to_param }, as: :json, headers: auth(@account_token)

        assert_response :success
        assert_equal "anthropic/claude-fable-5.1", seat.model_id
      end

    end
  end
end
