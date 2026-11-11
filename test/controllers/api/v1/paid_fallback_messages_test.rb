require "test_helper"

# #690 slice C: a post a resident makes while running on its paid fallback is
# labelled wherever it lands, including a conversation other than the one
# whose run it is, where the post can't be linked to the run.
class Api::V1::PaidFallbackMessagesTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @user = users(:confirmed_user)
    @home = @agent.account.chats.create!(title: "Where the run is", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
    @elsewhere = @agent.account.chats.create!(title: "Elsewhere", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
    @token = ApiKey.generate_for(@user, name: "Fallback", agent: @agent).raw_token
    @run = @home.agent_runtime_interactions.create!(agent: @agent, trigger_kind: "conversation",
      started_at: Time.current, run_id: SecureRandom.uuid, execution_state: "running",
      dispatch_claimed_at: Time.current, execution_deadline_at: 10.minutes.from_now,
      activity_token_expires_at: 20.minutes.from_now, provider: "house", model: "fallback/anthropic/claude-opus-5.5")
  end

  def post_to(chat, content, **options)
    post api_v1_conversation_messages_url(chat), params: { content: content }.merge(options),
      headers: { "Authorization" => "Bearer #{@token}" }
    assert_response :created
    chat.messages.order(:id).last
  end

  test "a post linked to the fallback run is labelled from it" do
    message = post_to(@home, "Here", runtime_run_id: @run.run_id)
    assert_equal @run, message.runtime_interaction
    assert_equal "Claude Opus 5.5", message.paid_fallback[:model_label]
    assert_equal "paid by this account's OpenRouter key", response.parsed_body.dig("message", "paid_fallback", "payer_label")
  end

  test "an unlinked post in another conversation during the fallback run is labelled too" do
    message = post_to(@elsewhere, "Over here")
    assert_nil message.runtime_interaction
    assert_equal @run, message.paid_fallback_interaction
    assert_equal "Claude Opus 5.5", response.parsed_body.dig("message", "paid_fallback", "model_label")
  end

  test "no live fallback run, no label: finished, or its activity window closed" do
    @run.update!(finished_at: Time.current)
    assert_nil post_to(@elsewhere, "After").paid_fallback

    @run.update!(finished_at: nil, activity_token_expires_at: 1.minute.ago)
    assert_nil post_to(@elsewhere, "Late").paid_fallback

    @run.update!(activity_token_expires_at: 20.minutes.from_now, provider: "xai", model: "grok-build-0.1")
    assert_nil post_to(@elsewhere, "On the plan").paid_fallback
  end

end
