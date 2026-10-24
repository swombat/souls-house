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

  test "triggers for one Telegram subscription share a concurrency key" do
    assert_equal(
      "telegram-subscription-#{@subscription.id}",
      TelegramAgentTriggerJob.concurrency_key.call(@subscription, @message)
    )
  end

  test "sends nothing for a paused, inactive or tokenless agent" do
    {
      paused: { paused: true },
      inactive: { active: false },
      tokenless: { trigger_bearer_token: nil }
    }.each do |label, attrs|
      @agent.reload.update!(attrs)
      sent = false

      ExternalAgentTelegramRequest.stub :new, ->(**) { sent = true; flunk "#{label} agent was sent a request" } do
        TelegramAgentTriggerJob.new.perform(@subscription.reload, @message)
      end

      refute sent, "#{label} agent was sent a request"
      @agent.update!(paused: false, active: true, trigger_bearer_token: "tr_valid")
    end
  end

end
