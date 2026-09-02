require "test_helper"

class ChatToolsFlowTest < ActionDispatch::IntegrationTest

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

  test "agent chat creation ignores model-chat web access" do
    assert_difference "Chat.count" do
      post account_chats_path(@account), params: {
        chat: { model_id: "openai/gpt-4o-mini", web_access: true },
        agent_ids: [ @agent.to_param ]
      }
    end

    chat = Chat.last
    assert_not chat.web_access
    assert_empty chat.available_tools

    # Navigate to the chat
    get account_chat_path(@account, chat)
    assert_response :success

    # Send a message that would benefit from web access
    assert_difference "Message.count" do
      assert_no_enqueued_jobs only: AiResponseJob do
        post account_chat_messages_path(@account, chat), params: {
          message: { content: "What's the latest news about Ruby on Rails?" }
        }
      end
    end

    user_message = chat.messages.last
    assert_equal "What's the latest news about Ruby on Rails?", user_message.content
    assert_equal "user", user_message.role
    assert_equal @user, user_message.user
  end

  test "create chat with web access disabled by default" do
    # Create chat without specifying web_access
    assert_difference "Chat.count" do
      post account_chats_path(@account), params: {
        agent_ids: [ @agent.to_param ]
      }
    end

    chat = Chat.last
    assert_not chat.web_access, "Chat should not have web access by default"
    assert_empty chat.available_tools, "No tools should be available by default"
  end

  test "legacy web access setting can be toggled without restoring retired tools" do
    # Create chat with web access disabled
    chat = @account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: false
    )
    assert_not chat.web_access
    assert_empty chat.available_tools

    # Enable web access
    patch account_chat_path(@account, chat), params: {
      chat: { web_access: true }
    }
    assert_redirected_to account_chat_path(@account, chat)

    chat.reload
    assert chat.web_access, "Web access should now be enabled"
    assert_empty chat.available_tools, "Retired model-chat tools should remain unavailable"

    # Disable web access again
    patch account_chat_path(@account, chat), params: {
      chat: { web_access: false }
    }
    assert_redirected_to account_chat_path(@account, chat)

    chat.reload
    assert_not chat.web_access, "Web access should be disabled again"
    assert_empty chat.available_tools, "Tools should no longer be available"
  end

  test "legacy web access setting does not configure AI response tools" do
    chat = @account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: true
    )

    chat.messages.create!(
      content: "Please check https://example.com",
      role: "user",
      user: @user
    )

    assert chat.web_access
    assert_empty chat.available_tools
  end

  test "tools_used tracked in message after AI response" do
    # This test verifies the complete integration but doesn't actually call external APIs
    # The actual tool execution is tested in ai_response_job_test.rb with mocking

    chat = @account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: true
    )

    # Create an AI message with tools_used populated
    ai_message = chat.messages.create!(
      role: "assistant",
      content: "I fetched the website and here's what I found...",
      tools_used: [ "Web fetch" ]
    )

    assert ai_message.used_tools?, "Message should indicate tools were used"
    assert_includes ai_message.tools_used, "Web fetch"

    # Verify the message JSON includes tools_used
    message_json = ai_message.as_json
    assert_equal [ "Web fetch" ], message_json["tools_used"]
  end

  test "complete flow from agent chat creation to another message" do
    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        assert_no_enqueued_jobs only: AiResponseJob do
          post account_chats_path(@account), params: {
            chat: { model_id: "openai/gpt-4o-mini", web_access: true },
            message: "Search for information about Ruby 3.4",
            agent_ids: [ @agent.to_param ]
          }
        end
      end
    end

    chat = Chat.last
    user_message = chat.messages.last

    assert_not chat.web_access
    assert_empty chat.available_tools

    # Verify user message was created correctly
    assert_equal "Search for information about Ruby 3.4", user_message.content
    assert_equal "user", user_message.role
    assert_equal @user, user_message.user

    # Navigate to the chat page
    get account_chat_path(@account, chat)
    assert_response :success

    # Add another message
    assert_difference "Message.count" do
      assert_no_enqueued_jobs only: AiResponseJob do
        post account_chat_messages_path(@account, chat), params: {
          message: { content: "What are the new features?" }
        }
      end
    end

    # Agent chats remain manual-response conversations for subsequent messages.
    chat.reload
    assert chat.manual_responses?
    assert_equal [ @agent ], chat.agents
  end

  test "web access setting persists across page views" do
    # Create chat with web access enabled
    chat = @account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: true
    )

    # View the chat
    get account_chat_path(@account, chat)
    assert_response :success

    # Reload and verify setting persists
    chat.reload
    assert chat.web_access
    assert_empty chat.available_tools

    # View the chat list
    get account_chats_path(@account)
    assert_response :success

    # Reload and verify setting still persists
    chat.reload
    assert chat.web_access
    assert_empty chat.available_tools
  end

  test "different chats can have different web access settings" do
    # Create chat with web access enabled
    chat_with_web = @account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: true,
      title: "Chat with Web Access"
    )

    # Create chat with web access disabled
    chat_without_web = @account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: false,
      title: "Chat without Web Access"
    )

    # Verify each chat has correct settings
    assert chat_with_web.web_access
    assert_empty chat_with_web.available_tools

    assert_not chat_without_web.web_access
    assert_empty chat_without_web.available_tools

    # View both chats and verify settings persist
    get account_chat_path(@account, chat_with_web)
    assert_response :success

    get account_chat_path(@account, chat_without_web)
    assert_response :success

    # Reload and verify settings are unchanged
    chat_with_web.reload
    chat_without_web.reload

    assert chat_with_web.web_access
    assert_not chat_without_web.web_access
  end

  test "web access can be toggled mid-conversation" do
    # Create chat and add some messages
    chat = @account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: false
    )

    # Add initial message without web access
    message1 = chat.messages.create!(
      content: "Hello",
      role: "user",
      user: @user
    )

    # Enable web access
    patch account_chat_path(@account, chat), params: {
      chat: { web_access: true }
    }
    assert_redirected_to account_chat_path(@account, chat)

    chat.reload
    assert chat.web_access

    # Add another message with web access enabled
    message2 = chat.messages.create!(
      content: "Now check https://example.com",
      role: "user",
      user: @user
    )

    # Verify both messages exist in the same chat
    assert_equal chat, message1.chat
    assert_equal chat, message2.chat

    # Disable web access again
    patch account_chat_path(@account, chat), params: {
      chat: { web_access: false }
    }
    assert_redirected_to account_chat_path(@account, chat)

    chat.reload
    assert_not chat.web_access
    assert_empty chat.available_tools
  end

  test "unauthenticated users cannot toggle web access" do
    chat = @account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: false
    )

    # Logout
    delete logout_path

    # Try to enable web access
    patch account_chat_path(@account, chat), params: {
      chat: { web_access: true }
    }
    assert_response :redirect

    # Verify web access was not enabled
    chat.reload
    assert_not chat.web_access
  end

  test "user cannot modify web access for chats in other accounts" do
    # Create another user and account
    other_user = User.create!(email_address: "toolsother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(
      model_id: "openai/gpt-4o-mini",
      web_access: false
    )

    # Try to enable web access on other account's chat
    patch account_chat_path(@account, other_chat), params: {
      chat: { web_access: true }
    }
    assert_response :not_found

    # Verify web access was not enabled
    other_chat.reload
    assert_not other_chat.web_access
  end

end
