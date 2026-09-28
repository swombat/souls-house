require "test_helper"
class MiraDiscardTelegramReviewTest < ActiveSupport::TestCase

  test "review: queued Telegram notification does not send discarded content" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Notify discard")
    message = chat.messages.create!(role: "assistant", agent: agent, content: "Discarded secret")
    subscription = agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 99112233)
    subscription.agent = agent
    message.discard!
    captured = nil
    spy = ->(*args, **options) { captured = args }
    agent.stub(:telegram_configured?, true) do
      agent.stub(:telegram_send_message, spy) do
        TelegramNotificationJob.perform_now(subscription, message.reload, chat)
      end
    end
    assert_nil captured, "discarded content was sent: #{captured.inspect}"
  end

end

class DiscardTelegramStillSendsTest < ActiveSupport::TestCase

  test "a kept message is still sent" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Notify kept")
    message = chat.messages.create!(role: "assistant", agent: agent, content: "Kept body")
    subscription = agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 99112234)
    captured = nil
    spy = ->(*args, **options) { captured = args }
    agent.stub(:telegram_configured?, true) do
      agent.stub(:telegram_send_message, spy) do
        TelegramNotificationJob.perform_now(subscription, message, chat)
      end
    end
    assert_includes captured.last, "Kept body"
  end

end
