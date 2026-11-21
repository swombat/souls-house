require "test_helper"

module Api
  module V1
    class TelegramConversationsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @api_key = ApiKey.generate_for(@user, name: "Agent Telegram history", agent: @agent)
        @subscription = @agent.telegram_subscriptions.create!(
          user: users(:user_1),
          telegram_chat_id: 111,
          telegram_username: "daniel_t"
        )
        @subscription.telegram_messages.create!(
          role: "user",
          text: "Did I actually say this?",
          sender_name: "Daniel",
          sender_username: "daniel_t",
          telegram_message_id: 7,
          sent_at: Time.zone.parse("2026-07-17 09:00:00")
        )
      end

      test "agent-scoped key reads its Telegram thread history" do
        get api_v1_telegram_conversation_url(@subscription),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

        assert_response :ok
        conversation = JSON.parse(response.body).fetch("conversation")
        assert_equal @subscription.to_param, conversation["thread_id"]
        assert_equal "telegram", conversation["channel"]
        assert_equal "daniel_t", conversation.dig("subscriber", "telegram_username")
        assert_equal "Did I actually say this?", conversation.dig("transcript", 0, "text")
      end

      test "after and through narrow the history to a stretch between two cursors" do
        first = @subscription.telegram_messages.first
        second = @subscription.telegram_messages.create!(role: "user", text: "second", sender_name: "Daniel", sent_at: Time.zone.parse("2026-07-17 09:01:00"))
        third = @subscription.telegram_messages.create!(role: "user", text: "third", sender_name: "Daniel", sent_at: Time.zone.parse("2026-07-17 09:02:00"))
        @subscription.telegram_messages.create!(role: "user", text: "fourth", sender_name: "Daniel", sent_at: Time.zone.parse("2026-07-17 09:03:00"))

        get api_v1_telegram_conversation_url(@subscription, after: first.to_param, through: third.to_param),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

        assert_response :ok
        transcript = JSON.parse(response.body).dig("conversation", "transcript")
        assert_equal [second.to_param, third.to_param], transcript.map { |message| message["id"] }
      end

      test "an unreadable cursor is refused rather than read as the whole thread" do
        get api_v1_telegram_conversation_url(@subscription, after: "!!"),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

        assert_response :unprocessable_entity
      end

      test "agent cannot read another agent's Telegram thread" do
        other_agent = agents(:code_reviewer)
        other_subscription = other_agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 222)

        get api_v1_telegram_conversation_url(other_subscription),
          headers: { "Authorization" => "Bearer #{@api_key.raw_token}" }

        assert_response :not_found
      end

      test "user-scoped key cannot read Telegram history" do
        user_key = ApiKey.generate_for(@user, name: "User Telegram history")

        get api_v1_telegram_conversation_url(@subscription),
          headers: { "Authorization" => "Bearer #{user_key.raw_token}" }

        assert_response :forbidden
      end

    end
  end
end
