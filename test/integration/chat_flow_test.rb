require "test_helper"

class ChatFlowTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)

    # Sign in user
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "complete chat creation and messaging flow" do
    # Start from index page
    get account_chats_path(@account)
    assert_response :success

    # Create a new chat with initial message
    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        assert_no_enqueued_jobs only: AiResponseJob do
          post account_chats_path(@account), params: {
            message: "Hello, I need help with coding",
            agent_ids: [ @agent.to_param ]
          }
        end
      end
    end

    chat = Chat.last
    user_message = chat.messages.last

    assert_equal "openrouter/auto", chat.model_id
    assert_equal "Hello, I need help with coding", user_message.content
    assert_equal "user", user_message.role
    assert_equal @user, user_message.user
    assert chat.manual_responses?
    assert_equal [ @agent ], chat.agents

    # Should redirect to chat page
    assert_redirected_to account_chat_path(@account, chat)
    follow_redirect!

    # Chat page should display correctly
    assert_response :success
    # Chat page should load successfully
    # Title depends on whether title generation has occurred

    # Add another message to the conversation
    assert_difference "Message.count" do
      assert_no_enqueued_jobs only: AiResponseJob do
        post account_chat_messages_path(@account, chat), params: {
          message: { content: "Specifically about Ruby on Rails" }
        }
      end
    end

    new_message = Message.last
    assert_equal "Specifically about Ruby on Rails", new_message.content
    assert_equal "user", new_message.role
    assert_equal @user, new_message.user
    assert_equal chat, new_message.chat

    # Should stay on chat page
    assert_redirected_to account_chat_path(@account, chat)
  end

  test "chat discard and restore preserve its messages and files" do
    chat = @account.chats.create!(
      model_id: "gpt-4o",
      title: "Test Chat"
    )
    message = chat.messages.create!(
      content: "Test message",
      role: "user",
      user: @user
    )
    message.attachments.attach(
      io: StringIO.new("retained bytes"),
      filename: "note.txt",
      content_type: "text/plain"
    )
    blob = message.attachments.first.blob

    post account_chat_discard_path(@account, chat)

    assert_redirected_to account_chats_path(@account)
    assert chat.reload.discarded?
    assert Chat.exists?(chat.id)
    assert Message.exists?(message.id)
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_equal "retained bytes", blob.download
    assert_equal "Test message", message.reload.content

    delete account_chat_discard_path(@account, chat)

    assert_redirected_to account_chats_path(@account)
    assert_not chat.reload.discarded?
    assert Message.exists?(message.id)
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_equal blob.id, message.reload.attachments.first.blob_id
    assert_equal "retained bytes", blob.download
  end

  test "account scoping prevents access to other accounts chats" do
    # Create another user and account
    other_user = User.create!(
      email_address: "flowother@example.com"
    )
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(
      model_id: "gpt-4o",
      title: "Other Account Chat"
    )

    # Should not be able to access other account's chat
    get account_chat_path(@account, other_chat)
    assert_response :not_found

    # Should not be able to post messages to other account's chat
    post account_chat_messages_path(@account, other_chat), params: {
      message: { content: "Should not work" }
    }
    assert_response :not_found

    # The legacy hard-delete URL is no longer routed.
    delete account_chat_path(@account, other_chat)
    assert_response :not_found

    # Chat should still exist
    assert Chat.exists?(other_chat.id)
  end

  test "unauthenticated users cannot access chats" do
    # Logout
    delete logout_path

    # Should redirect all chat endpoints
    get account_chats_path(@account)
    assert_response :redirect

    get account_chat_path(@account, "dummy-id")
    assert_response :redirect

    post account_chats_path(@account)
    assert_response :redirect

    post account_chat_messages_path(@account, "dummy-chat"), params: {
      message: { content: "Test" }
    }
    assert_response :redirect
  end

end
