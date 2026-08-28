require "test_helper"
require "ostruct"

class SafeguardWeeklyDigestJobTest < ActiveJob::TestCase

  test "sends a digest for classifier failures even when there were no detections" do
    agent = agents(:research_assistant)
    account = agent.account
    agent.update!(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
    subscription = agent.telegram_subscriptions.create!(
      user: account.owner,
      telegram_chat_id: 441
    )
    agent.safeguard_classifier_failures.create!(
      provider: "openrouter",
      model: "openai/gpt-5.6-luna",
      detector_version: "telegram-safeguard-v1",
      error_class: "Timeout::Error"
    )
    sent_text = nil
    fake_ok = OpenStruct.new(
      body: {
        "ok" => true,
        "result" => { "message_id" => 92, "date" => Time.current.to_i }
      }.to_json
    )

    Net::HTTP.stub :post, ->(_uri, body, _headers) {
      sent_text = JSON.parse(body).fetch("text")
      fake_ok
    } do
      SafeguardWeeklyDigestJob.perform_now
    end

    assert_includes sent_text, "Detections: 0"
    assert_includes sent_text, "Classifier failures: 1"
    assert_equal "souls.house", subscription.telegram_messages.last.sender_name
  end

end
