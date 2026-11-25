require "test_helper"

class Message::ReasoningSkipTest < ActiveSupport::TestCase

  setup do
    @user = User.create!(email_address: "rsk-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @user.profile.update!(first_name: "Rsk", last_name: "User")
    @account = @user.personal_account
    @chat = @account.chats.create!(model_id: "openrouter/auto")
  end

  test "inferred legacy_no_signature when thinking_text present and replay_payload blank" do
    msg = @chat.messages.create!(role: "assistant", content: "Old reply", thinking: "Some legacy thinking")

    assert_nil msg.reload[:reasoning_skip_reason], "the inference is not written back"
    assert_equal "legacy_no_signature", msg.reasoning_skip_reason
  end

  test "no skip reason when thinking_text blank" do
    msg = @chat.messages.create!(role: "assistant", content: "Reply")

    assert_nil msg.reasoning_skip_reason
  end

  test "user messages never get inferred legacy_no_signature" do
    msg = @chat.messages.create!(role: "user", user: @user, content: "Hello", thinking: "not a model turn")
    assert_nil msg.reasoning_skip_reason
  end

  test "json includes reasoning_skip_reason and reasoning_skip_reason_label" do
    msg = @chat.messages.create!(role: "assistant", content: "Reply", reasoning_skip_reason: "tool_continuity_missing")
    json = msg.as_json
    assert_equal "tool_continuity_missing", json["reasoning_skip_reason"]
    assert_match(/Thinking degraded/, json["reasoning_skip_reason_label"])
  end

end
