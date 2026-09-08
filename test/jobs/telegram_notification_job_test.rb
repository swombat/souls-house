require "test_helper"
require "ostruct"

class TelegramNotificationJobTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @fake_ok = OpenStruct.new(body: { "ok" => true, "result" => {} }.to_json)
    @agent = Net::HTTP.stub :post, @fake_ok do
      @account.agents.create!(
        name: "Notify Agent",
        telegram_bot_token: "123:ABC",
        telegram_bot_username: "notify_bot"
      )
    end
    chat = @account.chats.new(
      title: "Test Chat",
      model_id: "openrouter/auto",
      manual_responses: true
    )
    chat.agent_ids = [ @agent.id ]
    chat.save!
    @chat = chat
    @message = @chat.messages.create!(role: "assistant", agent: @agent, content: "Hello from agent")
    @subscription = @agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 12345)
  end

  test "sends notification for active subscription" do
    Net::HTTP.stub :post, @fake_ok do
      assert_nothing_raised do
        TelegramNotificationJob.perform_now(@subscription, @message, @chat)
      end
    end
  end

  test "skips blocked subscriptions" do
    @subscription.update!(blocked: true)
    # Should return early without error
    assert_nothing_raised do
      TelegramNotificationJob.perform_now(@subscription, @message, @chat)
    end
  end

  test "marks subscription blocked on blocked error" do
    fake_error = OpenStruct.new(body: { "ok" => false, "description" => "Forbidden: bot was blocked by the user" }.to_json)
    Net::HTTP.stub :post, fake_error do
      TelegramNotificationJob.perform_now(@subscription, @message, @chat)
    end
    assert @subscription.reload.blocked?
  end

  test "marks subscription blocked on chat not found error" do
    fake_error = OpenStruct.new(body: { "ok" => false, "description" => "Bad Request: chat not found" }.to_json)
    Net::HTTP.stub :post, fake_error do
      TelegramNotificationJob.perform_now(@subscription, @message, @chat)
    end
    assert @subscription.reload.blocked?
  end

  test "does not block subscription on other errors" do
    fake_error = OpenStruct.new(body: { "ok" => false, "description" => "Internal Server Error" }.to_json)
    Net::HTTP.stub :post, fake_error do
      # retry_on catches the re-raised error; just verify subscription is NOT blocked
      TelegramNotificationJob.perform_now(@subscription, @message, @chat)
    end
    assert_not @subscription.reload.blocked?
  end

  test "omits the Open Conversation link when public_url is not configured" do
    captured = nil
    spy = ->(_uri, body, _headers) { captured = JSON.parse(body); @fake_ok }

    Rails.configuration.x.stub :public_url, nil do
      Net::HTTP.stub :post, spy do
        TelegramNotificationJob.perform_now(@subscription, @message, @chat)
      end
    end

    assert_not_nil captured
    assert_not captured.key?("reply_markup")
  end

  test "includes the Open Conversation link when public_url is configured" do
    captured = nil
    spy = ->(_uri, body, _headers) { captured = JSON.parse(body); @fake_ok }

    Rails.configuration.x.stub :public_url, "https://example.test" do
      Net::HTTP.stub :post, spy do
        TelegramNotificationJob.perform_now(@subscription, @message, @chat)
      end
    end

    expected_url = "https://example.test/accounts/#{@chat.account_id}/chats/#{@chat.to_param}"
    assert_equal expected_url, captured.dig("reply_markup", "inline_keyboard", 0, 0, "url")
  end

  test "skips when agent not configured" do
    agent = @account.agents.create!(name: "Unconfigured Agent")
    sub = agent.telegram_subscriptions.create!(user: @user, telegram_chat_id: 999)
    chat = @account.chats.new(title: "T", model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!
    message = chat.messages.create!(role: "assistant", agent: agent, content: "Hey")

    assert_nothing_raised do
      TelegramNotificationJob.perform_now(sub, message, chat)
    end
  end

end
