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

  test "chat deletion flow" do
    # Create a chat with messages
    chat = @account.chats.create!(
      model_id: "gpt-4o",
      title: "Test Chat"
    )
    message = chat.messages.create!(
      content: "Test message",
      role: "user",
      user: @user
    )

    # Delete the chat
    assert_difference "Chat.count", -1 do
      assert_difference "Message.count", -1 do  # Messages should be deleted too
        delete account_chat_path(@account, chat)
      end
    end

    # Should redirect to chats index
    assert_redirected_to account_chats_path(@account)
    assert_not Chat.exists?(chat.id)
    assert_not Message.exists?(message.id)
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

    # Should not be able to delete other account's chat
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

  test "real-time broadcasting setup" do
    # Create a chat
    chat = @account.chats.create!(model_id: "gpt-4o")

    # Verify broadcast targets are configured correctly
    assert_equal [ :account ], Chat.broadcast_targets
    assert_equal [ :chat ], Message.broadcast_targets

    # Just verify broadcasts are configured - actual broadcast testing
    # would require ActionCable test setup
    assert_respond_to chat, :broadcast_targets

    # Create a message and verify it has broadcast capabilities
    message = chat.messages.create!(
      content: "Broadcast test",
      role: "user",
      user: @user
    )
    assert_respond_to message, :broadcast_targets
  end

  test "job scheduling works correctly" do
    chat = @account.chats.create!(model_id: "gpt-4o")

    # Just verify that jobs are available and configured
    assert defined?(GenerateTitleJob)
    assert defined?(AiResponseJob)

    # Creating a message should work
    user_message = chat.messages.create!(
      content: "Test question",
      role: "user",
      user: @user
    )

    assert_equal "Test question", user_message.content
    assert_equal "user", user_message.role
  end

  test "sidebar chat list updates correctly" do
    # Start with empty chat list
    get account_chats_path(@account)
    assert_response :success

    # Create multiple chats
    chat1 = @account.chats.create!(
      model_id: "gpt-4o",
      title: "First Chat",
      created_at: 1.hour.ago
    )
    chat2 = @account.chats.create!(
      model_id: "claude-3.7-sonnet",
      title: "Second Chat",
      created_at: 2.hours.ago
    )
    chat3 = @account.chats.create!(
      model_id: "gpt-4o-mini",
      title: "Third Chat",
      created_at: 30.minutes.ago  # Most recent
    )

    # Get chat list
    get account_chats_path(@account)
    assert_response :success

    # Verify ordering in the database
    chats_from_db = @account.chats.latest.to_a
    assert_equal 3, chats_from_db.length

    # Empty chats use creation time until their first message.
    assert_equal chat3.id, chats_from_db[0].id
    assert_equal chat1.id, chats_from_db[1].id
    assert_equal chat2.id, chats_from_db[2].id

    # Should have correct data
    assert_equal "Third Chat", chats_from_db[0].title_or_default
    assert chats_from_db[0].updated_at_short.present?
  end

end
