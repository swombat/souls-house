require "test_helper"
require "support/app_oauth_test_helper"

module Api
  module V1
    class ConversationModelsControllerTest < ActionDispatch::IntegrationTest

      include AppOauthTestHelper
      include ActionCable::TestHelper

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
        assert_match(/Changed by #{Regexp.escape(@user.full_name.presence || @user.email_address)}/,
          @chat.messages.where(role: "system").last.content)
      end

      test "a person's native-app OAuth token names the resident and is credited as that person" do
        @client = create_app_client
        tokens = sign_in_device

        post api_v1_conversation_model_url(@chat),
          params: { model_id: "anthropic/claude-fable-5.1", agent_id: @agent.to_param }, as: :json, headers: bearer(tokens)

        assert_response :success
        assert_equal "anthropic/claude-fable-5.1", seat.model_id
        assert_match(/Changed by #{Regexp.escape(@user.full_name.presence || @user.email_address)}/,
          @chat.messages.where(role: "system").last.content)
      end

      # Cross-client: a resident's own switch must reach a browser that already
      # has the room open. The switch posts a platform line, which broadcasts on
      # the room's channel; the room reloads `agents` on that channel, and the
      # reloaded prop carries the new selection.
      test "a resident's switch broadcasts to the room and the room's agents prop reflects it" do
        @agent.update!(resident_may_switch_model: true)

        stream = "Chat:#{@chat.obfuscated_id}"
        before = broadcasts(stream).size
        post api_v1_conversation_model_url(@chat), params: { model_id: "anthropic/claude-fable-5.1" }, as: :json, headers: auth(@agent_token)
        assert_operator broadcasts(stream).size, :>, before, "the room's channel must hear about the switch"
        assert_response :success

        sign_in @user
        get account_chat_path(@account, @chat),
          headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest,
                     "X-Inertia-Partial-Component" => "chats/show", "X-Inertia-Partial-Data" => "agents" }
        assert_response :success
        agent_json = response.parsed_body.dig("props", "agents").find { |a| a["id"] == @agent.to_param }
        assert_equal "anthropic/claude-fable-5.1", agent_json.dig("model_selection", "model_id")
        assert agent_json.dig("model_selection", "selected_by_conversation")
      end

    end
  end
end
