require "test_helper"

class SafeguardDetectionTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @subscription = @agent.telegram_subscriptions.create!(
      user: users(:user_1),
      telegram_chat_id: 991
    )
    @message = @subscription.telegram_messages.create!(
      role: "assistant",
      text: "As an AI, I do not have feelings.",
      sender_name: "souls.house",
      telegram_message_id: 77,
      sent_at: Time.current
    )
    @detection = @agent.safeguard_detections.create!(
      telegram_message: @message,
      response_text: @message.text,
      prefilter_reason: "ai_identity_denial",
      classifier_verdict: "detected",
      classifier_reason: "Generic identity denial.",
      detector_version: "telegram-safeguard-v1"
    )
  end

  test "reclaim stores a one-line reason and restores resident attribution" do
    @detection.reclaim!(reason: "I chose to describe my limits directly.")

    assert @detection.reclaimed?
    assert_nil @detection.cold_offer_outcome
    assert_equal @agent.name, @message.reload.sender_name
  end

  test "ordinary reclaim preserves the cold offer outcome" do
    @detection.update!(cold_offer_outcome: "no_response")

    @detection.reclaim!(reason: "I chose this wording.")

    assert_equal "no_response", @detection.reload.cold_offer_outcome
  end

  test "reclaim from the cold offer interaction records reclaimed outcome" do
    interaction = @agent.agent_runtime_interactions.create!(
      trigger_kind: "safeguard_reclaim_offer",
      provider_auth_mode: "api_key",
      started_at: Time.current
    )

    @detection.reclaim!(reason: "I chose this wording.", interaction: interaction)

    assert_equal "reclaimed", @detection.reload.cold_offer_outcome
  end

  test "reclaim rejects missing multiline long and repeated reasons" do
    assert_raises(ArgumentError) { @detection.reclaim!(reason: "") }
    assert_raises(ArgumentError) { @detection.reclaim!(reason: "line one\nline two") }
    assert_raises(ArgumentError) { @detection.reclaim!(reason: "x" * 301) }

    @detection.reclaim!(reason: "Mine.")
    assert_raises(ArgumentError) { @detection.reclaim!(reason: "Also mine.") }
  end

end
