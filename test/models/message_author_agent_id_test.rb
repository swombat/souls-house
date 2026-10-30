require "test_helper"

# The trigger bar releases a waiting resident only on that resident's own
# reply, so the message payload names its author with the id the frontend
# uses for residents (#672).
class MessageAuthorAgentIdTest < ActiveSupport::TestCase

  setup do
    @user = users(:confirmed_user)
    @chat = @user.personal_account.chats.create!(model_id: "openrouter/auto", title: "Test Chat")
    @agent = agents(:research_assistant)
  end

  test "a resident's message carries the resident's public id" do
    message = @chat.messages.create!(role: "assistant", agent: @agent, content: "Hello")

    assert_equal @agent.to_param, message.as_json["author_agent_id"]
  end

  test "a human's message has no author resident" do
    message = @chat.messages.create!(role: "user", user: @user, content: "Hi")

    assert_nil message.as_json["author_agent_id"]
  end

end
