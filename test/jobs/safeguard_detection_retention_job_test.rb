require "test_helper"

class SafeguardDetectionRetentionJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @subscription = @agent.telegram_subscriptions.create!(
      user: users(:user_1),
      telegram_chat_id: 992
    )
  end

  test "redacts expired detection text while preserving metadata and delivered message" do
    detection = create_detection(message_id: 101)
    detection.update_columns(created_at: 31.days.ago, updated_at: 31.days.ago)

    SafeguardDetectionRetentionJob.perform_now

    detection.reload
    assert_nil detection.response_text
    assert_not_nil detection.response_text_redacted_at
    assert_equal "Generic identity denial.", detection.classifier_reason
    assert_equal "As an AI, I do not have feelings.", detection.telegram_message.reload.text
  end

  test "keeps recent and resident-notice-pending detection text" do
    recent = create_detection(message_id: 102)
    recent.update_columns(created_at: 29.days.ago, updated_at: 29.days.ago)
    pending = create_detection(message_id: 103)
    pending.update_columns(created_at: 31.days.ago, updated_at: 31.days.ago)
    @subscription.update!(pending_safeguard_detection: pending)

    SafeguardDetectionRetentionJob.perform_now

    assert_not_nil recent.reload.response_text
    assert_not_nil pending.reload.response_text
  end

  private

  def create_detection(message_id:)
    message = @subscription.telegram_messages.create!(
      role: "assistant",
      text: "As an AI, I do not have feelings.",
      sender_name: "souls.house",
      telegram_message_id: message_id,
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
