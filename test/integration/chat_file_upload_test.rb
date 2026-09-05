require "test_helper"

class ChatFileUploadTest < ActionDispatch::IntegrationTest

  setup do
    # Ensure chats feature is enabled
    Setting.instance.update!(allow_chats: true)

    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "File Upload Test Chat"
    )

    # Sign in user
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
    follow_redirect!
  end

  test "complete file upload flow with single file" do
    # Navigate to the chat
    get account_chat_path(@account, @chat)
    assert_response :success

    # Upload a file with a message
    file = fixture_file_upload("test_image.png", "image/png")

    assert_difference "Message.count", 1 do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Here's an image for you to analyze" },
        files: [ file ]
      }
    end

    # Verify the message was created correctly
    message = Message.last
    assert_equal "Here's an image for you to analyze", message.content
    assert_equal "user", message.role
    assert_equal @user, message.user
    assert_equal @chat, message.chat

    # Verify file attachment
    assert message.attachments.attached?
    assert_equal 1, message.attachments.count
    assert_equal "test_image.png", message.attachments.first.filename.to_s
    assert_equal "image/png", message.attachments.first.content_type

    # Verify redirect back to chat
    assert_redirected_to account_chat_path(@account, @chat)
    follow_redirect!
    assert_response :success

    # Verify chat was touched (updated_at changed)
    @chat.reload
    assert @chat.updated_at > 1.minute.ago
  end

  test "complete file upload flow with multiple files" do
    image_file = fixture_file_upload("test_image.png", "image/png")
    pdf_file = fixture_file_upload("test_document.pdf", "application/pdf")

    assert_difference "Message.count", 1 do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Multiple files for analysis" },
        files: [ image_file, pdf_file ]
      }
    end

    message = Message.last
    assert_equal 2, message.attachments.count

    filenames = message.attachments.map { |f| f.filename.to_s }
    assert_includes filenames, "test_image.png"
    assert_includes filenames, "test_document.pdf"

    # Files are properly attached
    assert_equal 2, message.attachments.count

    # Test metadata is accessible via attached files directly
    message.attachments.each do |attached_file|
      assert attached_file.id.present?
      assert attached_file.filename.present?
      assert attached_file.content_type.present?
      assert attached_file.byte_size > 0
    end
  end

  test "file upload persists with message data" do
    file = fixture_file_upload("test_document.pdf", "application/pdf")

    post account_chat_messages_path(@account, @chat), params: {
      message: { content: "PDF document" },
      files: [ file ]
    }

    message = Message.last

    # Test that file persists after reload
    message.reload
    assert message.attachments.attached?
    assert_equal 1, message.attachments.count

    # Test that file data is accessible via attached files
    attached_file = message.attachments.first
    assert_equal "test_document.pdf", attached_file.filename.to_s
    assert_equal "application/pdf", attached_file.content_type
  end

  test "authorization - users can only upload to their own chats" do
    # Create another user and their chat
    other_user = User.create!(
      email_address: "otheruser@example.com"
    )
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(
      model_id: "gpt-4o",
      title: "Other User's Chat"
    )

    file = fixture_file_upload("test_image.png", "image/png")

    # Should return 404 when trying to upload to another user's chat
    assert_no_difference "Message.count" do
      post account_chat_messages_path(@account, other_chat), params: {
        message: { content: "Unauthorized upload attempt" },
        files: [ file ]
      }
    end

    assert_response :not_found
  end

  test "file upload with validation errors redirects with error message" do
    invalid_file = fixture_file_upload("test.exe", "application/x-msdownload")

    assert_no_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Invalid file upload" },
        files: [ invalid_file ]
      }
    end

    assert_response :redirect
    follow_redirect!

    # Verify error message is displayed
    assert_match /file type not supported/, flash[:alert]
    assert_response :success
  end

  test "message provides attachment download paths for harnesses" do
    file = fixture_file_upload("test_image.png", "image/png")

    post account_chat_messages_path(@account, @chat), params: {
      message: { content: "File for AI" },
      files: [ file ]
    }

    # Harnesses fetch attachments through the scoped API.
    message = Message.last
    file_paths = message.attachments_for_api.map { |file| file[:download_path] }
    assert_equal 1, file_paths.length
    assert file_paths.first.is_a?(String)
    assert file_paths.first.length > 0
  end

  test "empty files parameter does not cause errors" do
    assert_difference "Message.count", 1 do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Message without files" },
        files: []
      }
    end

    message = Message.last
    assert_not message.attachments.attached?
    assert_equal 0, message.attachments.count
    assert_equal [], message.files_json
    assert_equal [], message.attachments_for_api
  end

  test "large number of files can be handled" do
    files = []
    5.times do |i|
      files << fixture_file_upload("test_image.png", "image/png")
    end

    assert_difference "Message.count", 1 do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Many files" },
        files: files
      }
    end

    message = Message.last
    assert_equal 5, message.attachments.count
    # All files properly attached
    assert_equal 5, message.attachments.count
    assert_equal 5, message.attachments_for_api.length
  end

end
