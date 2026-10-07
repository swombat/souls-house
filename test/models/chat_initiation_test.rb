require "test_helper"

class ChatInitiationTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
  end

  test "agent initiation does not notify Telegram subscribers" do
    Net::HTTP.stub :post, ->(*) { Struct.new(:body).new({ ok: true }.to_json) } do
      @agent.update!(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
    end
    @agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 111)

    assert_no_enqueued_jobs only: TelegramNotificationJob do
      Chat.initiate_by_agent!(@agent, topic: "Consult", message: "An ordinary opening message")
    end
  end

  test "initiate_by_agent! creates chat with agent message" do
    chat = Chat.initiate_by_agent!(
      @agent,
      topic: "Weekly Check-in",
      message: "Hello everyone!",
      reason: "Time to discuss progress"
    )

    assert_equal "Weekly Check-in", chat.title
    assert_equal @agent, chat.initiated_by_agent
    assert_equal "Time to discuss progress", chat.initiation_reason
    assert chat.manual_responses?
    assert_equal 1, chat.messages.count
    assert_equal "assistant", chat.messages.first.role
    assert_equal @agent, chat.messages.first.agent
    assert_equal "Hello everyone!", chat.messages.first.content
  end

  test "initiate_by_agent! adds agent to chat" do
    chat = Chat.initiate_by_agent!(
      @agent,
      topic: "Test Topic",
      message: "Test message"
    )

    assert_includes chat.agents, @agent
  end

  test "initiate_by_agent! uses agent model_id" do
    chat = Chat.initiate_by_agent!(
      @agent,
      topic: "Test Topic",
      message: "Test message"
    )

    assert_equal @agent.model_id, chat.model_id
  end

  test "initiate_by_agent! works without reason" do
    chat = Chat.initiate_by_agent!(
      @agent,
      topic: "Test Topic",
      message: "Test message"
    )

    assert_nil chat.initiation_reason
    assert chat.persisted?
  end

  test "initiated scope returns only initiated chats" do
    regular_chat = @account.chats.create!(title: "Regular Chat")
    initiated_chat = Chat.initiate_by_agent!(
      @agent,
      topic: "Initiated Chat",
      message: "Hello!"
    )

    initiated = @account.chats.initiated

    assert_includes initiated, initiated_chat
    assert_not_includes initiated, regular_chat
  end

  test "awaiting_human_response scope returns chats without human messages" do
    chat = Chat.initiate_by_agent!(
      @agent,
      topic: "Awaiting Response",
      message: "Hello!"
    )

    awaiting = @account.chats.awaiting_human_response

    assert_includes awaiting, chat
  end

  test "awaiting_human_response scope excludes chats with human messages" do
    user = users(:user_1)
    chat = Chat.initiate_by_agent!(
      @agent,
      topic: "Responded To",
      message: "Hello!"
    )
    chat.messages.create!(role: "user", user: user, content: "Hi back!")

    awaiting = @account.chats.awaiting_human_response

    assert_not_includes awaiting, chat
  end

  test "awaiting_human_response only counts messages from actual users" do
    chat = Chat.initiate_by_agent!(
      @agent,
      topic: "Test Chat",
      message: "Hello!"
    )
    # Create a user message without a user_id (simulating system message)
    chat.messages.create!(role: "user", content: "System message")

    awaiting = @account.chats.awaiting_human_response

    # Should still be awaiting since the message has no user_id
    assert_includes awaiting, chat
  end

end
