require "test_helper"

class Messages::RetriesControllerTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_chats: true)

    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Test Conversation"
    )

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "retired inline retry preserves history and enqueues nothing" do
    @chat.messages.create!(user: @user, role: "user", content: "Original question")
    failed_message = @chat.messages.create!(role: "assistant", content: "Partial response")

    post message_retry_path(failed_message), as: :json
    assert_response :conflict

    assert_no_enqueued_jobs only: AiResponseJob
    assert_equal "Partial response", failed_message.reload.content
    assert_equal "inline_runtime_retired", response.parsed_body["code"]
  end

  test "retry should scope to current account" do
    other_user = User.create!(email_address: "retryother_new@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(model_id: "gpt-4o")
    other_message = other_chat.messages.create!(role: "assistant", content: "Failed")

    post message_retry_path(other_message)
    assert_response :not_found
  end

  test "retry requires authentication" do
    message = @chat.messages.create!(role: "assistant", content: "Some content")

    delete logout_path

    post message_retry_path(message)
    assert_response :redirect
  end

  test "retry rejects archived chat" do
    message = @chat.messages.create!(role: "assistant", content: "Some content")
    @chat.archive!

    post message_retry_path(message), as: :json
    assert_response :unprocessable_entity
  end

end
