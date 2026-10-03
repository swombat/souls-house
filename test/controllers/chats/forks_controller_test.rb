require "test_helper"

class Chats::ForksControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Test Conversation",
      manual_responses: true,
      agents: [ agents(:research_assistant) ]
    )

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "create forks the chat with custom title" do
    assert_difference "Chat.count" do
      post account_chat_fork_path(@account, @chat), params: { title: "My Fork" }
    end

    forked_chat = Chat.last
    assert_equal "My Fork", forked_chat.title
    assert forked_chat.group_chat?
    assert_equal @chat.agent_ids, forked_chat.agent_ids
    assert_redirected_to account_chat_path(@account, forked_chat)
  end

  test "historical bare-model chat remains readable but cannot be forked" do
    legacy = @account.chats.create!(title: "Historical model conversation", model_id: "openai/gpt-4o")
    legacy.messages.create!(role: "assistant", content: "Historical reply")

    get account_chat_path(@account, legacy)
    assert_response :success

    assert_no_difference [ "Chat.count", "Message.count", "AuditLog.count" ] do
      post account_chat_fork_path(@account, legacy), params: { title: "Bare fork" }
    end

    assert_redirected_to account_chat_path(@account, legacy)
    assert_match(/new resident conversations/, flash[:alert])
    assert_not legacy.reload.group_chat?
  end

  test "create forks the chat with default title when none provided" do
    assert_difference "Chat.count" do
      post account_chat_fork_path(@account, @chat)
    end

    forked_chat = Chat.last
    assert_match(/Fork/, forked_chat.title)
    assert_redirected_to account_chat_path(@account, forked_chat)
  end

  test "create creates audit log" do
    assert_difference "AuditLog.count" do
      post account_chat_fork_path(@account, @chat), params: { title: "My Fork" }
    end

    audit = AuditLog.last
    assert_equal "fork_chat", audit.action
    assert_equal @chat.id, audit.data["source_chat_id"]
  end

  test "requires authentication" do
    delete logout_path

    post account_chat_fork_path(@account, @chat)
    assert_response :redirect
  end

end
