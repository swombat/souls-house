require "test_helper"

class TelegramAgentTriggerJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid"
    )
    @subscription = @agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 111)
    @message = @subscription.telegram_messages.create!(
      role: "user",
      text: "Second message",
      sent_at: Time.current
    )
  end

  test "raises a retryable error when the persistent session is busy" do
    request = Minitest::Mock.new
    request.expect(:call, { status: 409 })

    ExternalAgentTelegramRequest.stub :new, ->(**) { request } do
      assert_raises(TelegramAgentTriggerJob::SessionBusy) do
        TelegramAgentTriggerJob.new.perform(@subscription, @message)
      end
    end

    request.verify
  end

  test "serializes triggers for the same Telegram subscription" do
    assert_equal 1, TelegramAgentTriggerJob.concurrency_limit
    assert_equal(
      "telegram-subscription-#{@subscription.id}",
      TelegramAgentTriggerJob.concurrency_key.call(@subscription, @message)
    )
    assert_equal 35.minutes, TelegramAgentTriggerJob.concurrency_duration
  end

end
