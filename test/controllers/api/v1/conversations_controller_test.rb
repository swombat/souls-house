require "test_helper"

module Api
  module V1
    class ConversationsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @api_key = ApiKey.generate_for(@user, name: "Test")
        @token = @api_key.raw_token
        @account = @user.personal_account
        @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Test Chat")
      end

      test "returns unauthorized without token" do
        get api_v1_conversations_url
        assert_response :unauthorized

        json = JSON.parse(response.body)
        assert_equal "Invalid or missing API key", json["error"]
      end

      test "returns unauthorized with invalid token" do
        get api_v1_conversations_url, headers: { "Authorization" => "Bearer invalid_token" }
        assert_response :unauthorized
      end

      test "lists conversations with valid token" do
        get api_v1_conversations_url, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        json = JSON.parse(response.body)
        assert json["conversations"].is_a?(Array)
        assert_nil json["next_cursor"]
      end

      test "paginates conversations with a cursor" do
        chats = 101.times.map do |index|
          @account.chats.create!(
            model_id: "openrouter/auto",
            title: "Chat #{index}",
            updated_at: index.minutes.ago
          )
        end

        get api_v1_conversations_url, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        first_page = JSON.parse(response.body)
        assert_equal 100, first_page["conversations"].length
        assert_equal first_page["conversations"].last["id"], first_page["next_cursor"]

        get api_v1_conversations_url,
          params: { cursor: first_page["next_cursor"] },
          headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        second_page = JSON.parse(response.body)
        assert_equal 2, second_page["conversations"].length
        assert_nil second_page["next_cursor"]
        assert_empty first_page["conversations"].map { |chat| chat["id"] } & second_page["conversations"].map { |chat| chat["id"] }
        assert_equal chats.last.to_param, second_page["conversations"].last["id"]
      end

      test "lists only active kept conversations" do
        # Create various chats
        active_chat = @account.chats.create!(model_id: "openrouter/auto", title: "Active")
        archived_chat = @account.chats.create!(model_id: "openrouter/auto", title: "Archived")
        archived_chat.archive!
        discarded_chat = @account.chats.create!(model_id: "openrouter/auto", title: "Discarded")
        discarded_chat.discard!

        get api_v1_conversations_url, headers: { "Authorization" => "Bearer #{@token}" }
        json = JSON.parse(response.body)

        ids = json["conversations"].map { |c| c["id"] }
        assert_includes ids, active_chat.to_param
        assert_not_includes ids, archived_chat.to_param
        assert_not_includes ids, discarded_chat.to_param
      end

      test "shows conversation with transcript" do
        @chat.messages.create!(content: "Hello", role: "user", user: @user)
        @chat.messages.create!(content: "Hi there!", role: "assistant")

        get api_v1_conversation_url(@chat), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        json = JSON.parse(response.body)
        assert_equal @chat.to_param, json["conversation"]["id"]
        assert_equal "Test Chat", json["conversation"]["title"]
        assert_equal 2, json["conversation"]["transcript"].length
      end

      test "filters transcript to messages after a given cursor" do
        first = @chat.messages.create!(content: "Hello", role: "user", user: @user)
        second = @chat.messages.create!(content: "Hi there!", role: "assistant")

        get api_v1_conversation_url(@chat), params: { after_message_id: first.to_param }, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        json = JSON.parse(response.body)
        transcript = json["conversation"]["transcript"]
        assert_equal 1, transcript.length
        assert_equal second.to_param, transcript.first["id"]
      end

      test "returns 404 for unknown conversation" do
        get api_v1_conversation_url("nonexistent"), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found

        json = JSON.parse(response.body)
        assert_equal "Not found", json["error"]
      end

      test "returns 404, not 500, for an id the obfuscator cannot decode" do
        # Digits are outside the hashid alphabet, so this raises Hashids::InputError
        # rather than RecordNotFound. The souls CLI maps 404 to exit 4.
        get api_v1_conversation_url("NOPE00"), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
        assert_equal "Not found", JSON.parse(response.body)["error"]
      end

      test "cannot access other user conversations" do
        other_user = users(:existing_user)
        other_account = other_user.personal_account
        other_chat = other_account.chats.create!(model_id: "openrouter/auto", title: "Other Chat")

        get api_v1_conversation_url(other_chat), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "updates api key last used timestamp" do
        assert_nil @api_key.reload.last_used_at

        get api_v1_conversations_url, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success

        @api_key.reload
        assert_not_nil @api_key.last_used_at
      end

    end
  end
end
