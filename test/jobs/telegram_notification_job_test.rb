require "test_helper"
require "ostruct"

class TelegramNotificationJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    Net::HTTP.stub :post, OpenStruct.new(body: { ok: true }.to_json) do
      @agent.update!(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
    end
    assert @agent.telegram_configured?
  end

  test "already queued notifications drain without sending or changing subscriptions" do
    agent = @agent
    chat = agent.account.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ agent ])
    message = chat.messages.create!(role: "assistant", agent: agent, content: "Do not forward")
    subscription = agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 12345)

    payload = TelegramNotificationJob.new(subscription, message, chat).serialize
    Net::HTTP.stub :post, ->(*) { flunk "Legacy notification must not contact Telegram" } do
      assert_no_enqueued_jobs only: TelegramNotificationJob do
        ActiveJob::Base.execute(payload)
      end
    end

    assert_not subscription.reload.blocked?
  end

  test "already queued notifications with missing records are discarded without retry" do
    agent = @agent
    chat = agent.account.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ agent ])
    message = chat.messages.create!(role: "assistant", agent: agent, content: "Gone")
    subscription = agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 12345)
    payload = TelegramNotificationJob.new(subscription, message, chat).serialize
    subscription.destroy!

    Net::HTTP.stub :post, ->(*) { flunk "Legacy notification must not contact Telegram" } do
      assert_no_enqueued_jobs only: TelegramNotificationJob do
        assert_nothing_raised { ActiveJob::Base.execute(payload) }
      end
    end
  end

end
