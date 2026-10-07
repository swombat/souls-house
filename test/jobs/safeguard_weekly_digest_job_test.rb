require "test_helper"
require "ostruct"

class SafeguardWeeklyDigestJobTest < ActiveJob::TestCase

  test "queued digest does not send or alter safeguard records" do
    agent = agents(:research_assistant)
    Net::HTTP.stub :post, OpenStruct.new(body: { ok: true }.to_json) do
      agent.update!(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
    end
    agent.telegram_subscriptions.create!(user: agent.account.owner, telegram_chat_id: 441)
    detection = agent.safeguard_detections.create!(
      response_text: "Possible safeguard",
      prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected",
      classifier_reason: "Generic identity denial.",
      detector_version: "telegram-safeguard-v1"
    )
    failure = agent.safeguard_classifier_failures.create!(
      provider: "openrouter",
      model: "openai/gpt-5.6-luna",
      detector_version: "telegram-safeguard-v1",
      error_class: "Timeout::Error"
    )
    assert agent.telegram_configured?
    assert_nil agent.account.disabled_at
    original_detection = detection.attributes
    original_failure = failure.attributes
    payload = SafeguardWeeklyDigestJob.new.serialize

    Net::HTTP.stub :post, ->(*) { flunk "Legacy digest must not contact Telegram" } do
      assert_no_difference [ "TelegramMessage.count", "SafeguardDetection.count", "SafeguardClassifierFailure.count" ] do
        assert_no_enqueued_jobs only: SafeguardWeeklyDigestJob do
          ActiveJob::Base.execute(payload)
        end
      end
    end

    assert_equal original_detection, detection.reload.attributes
    assert_equal original_failure, failure.reload.attributes
  end

end
