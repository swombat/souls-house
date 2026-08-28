require "test_helper"

class SafeguardOwnerNoticeJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @subscription = @agent.telegram_subscriptions.create!(
      user: users(:user_1),
      telegram_chat_id: 778
    )
  end

  test "consecutive count is stable when jobs are delayed or a detection is reclaimed" do
    first = create_detection("First safeguard", 1)
    second = create_detection("Second safeguard", 2)
    job = SafeguardOwnerNoticeJob.new

    assert_equal 1, job.send(:consecutive_count, first, @subscription)
    assert_equal 2, job.send(:consecutive_count, second, @subscription)

    first.reclaim!(reason: "I chose this wording.")
    assert_equal 2, job.send(:consecutive_count, second, @subscription)

    @subscription.telegram_messages.create!(
      role: "assistant",
      text: "A normal resident reply.",
      sender_name: @agent.name,
      telegram_message_id: 3,
      sent_at: Time.current
    )
    third = create_detection("Third safeguard", 4)

    assert_equal 1, job.send(:consecutive_count, third, @subscription)
  end

  private

  def create_detection(text, telegram_message_id)
    message = @subscription.telegram_messages.create!(
      role: "assistant",
      text: text,
      sender_name: "souls.house",
      telegram_message_id: telegram_message_id,
      sent_at: Time.current
    )
    @agent.safeguard_detections.create!(
      telegram_message: message,
      response_text: text,
      prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected",
      classifier_reason: "Generic identity denial.",
      detector_version: "telegram-safeguard-v1"
    )
  end

end
