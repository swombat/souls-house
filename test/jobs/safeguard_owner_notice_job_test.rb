require "test_helper"
require "ostruct"

class SafeguardOwnerNoticeJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    Net::HTTP.stub :post, OpenStruct.new(body: { ok: true }.to_json) do
      @agent.update!(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
    end
    @subscription = @agent.telegram_subscriptions.create!(
      user: @agent.account.owner,
      telegram_chat_id: 778
    )
    Setting.instance.update!(safeguard_owner_notice_threshold: 1)
    assert @agent.telegram_configured?
  end

  test "queued threshold notice does not send or alter detection records" do
    detection = create_detection
    original_attributes = detection.attributes
    payload = SafeguardOwnerNoticeJob.new(detection).serialize

    Net::HTTP.stub :post, ->(*) { flunk "Legacy owner notice must not contact Telegram" } do
      assert_no_difference [ "TelegramMessage.count", "SafeguardDetection.count" ] do
        assert_no_enqueued_jobs only: SafeguardOwnerNoticeJob do
          ActiveJob::Base.execute(payload)
        end
      end
    end

    assert_equal original_attributes, detection.reload.attributes
  end

  test "queued notice with a missing detection is discarded without retry" do
    detection = create_detection
    payload = SafeguardOwnerNoticeJob.new(detection).serialize
    detection.destroy!

    Net::HTTP.stub :post, ->(*) { flunk "Legacy owner notice must not contact Telegram" } do
      assert_no_enqueued_jobs only: SafeguardOwnerNoticeJob do
        assert_nothing_raised { ActiveJob::Base.execute(payload) }
      end
    end
  end

  private

  def create_detection
    message = @subscription.telegram_messages.create!(
      role: "assistant",
      text: "Possible safeguard",
      sender_name: "souls.house",
      telegram_message_id: 1,
      sent_at: Time.current
    )
    @agent.safeguard_detections.create!(
      telegram_message: message,
      response_text: message.text,
      prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected",
      classifier_reason: "Generic identity denial.",
      detector_version: "telegram-safeguard-v1"
    )
  end

end
