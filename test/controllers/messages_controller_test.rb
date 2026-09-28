require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest

  setup do
    # Ensure chats feature is enabled
    Setting.instance.update!(allow_chats: true)

    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Test Conversation"
    )

    # Sign in user
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "index includes estimated interaction costs for paginated messages" do
    agent = agents(:research_assistant)
    started_at = 1.minute.ago
    message = @chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "An older hosted response",
      created_at: started_at + 10.seconds
    )
    @chat.agent_runtime_interactions.create!(
      agent: agent,
      trigger_kind: "conversation",
      started_at: started_at,
      finished_at: started_at + 20.seconds,
      telemetry_schema_version: 1,
      usage_scope: "trigger",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-sonnet-5",
      uncached_input_tokens: 1_000,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 25
    )

    get account_chat_messages_path(@account, @chat), as: :json

    response_message = response.parsed_body["messages"].find { |row| row["id"] == message.to_param }
    assert_equal "0.00225", response_message.dig("interaction_cost", "amount_usd")
  end

  test "should create message and trigger AI response" do
    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Hello AI" }
      }
    end

    message = Message.last
    assert_equal "Hello AI", message.content
    assert_equal "user", message.role
    assert_equal @user, message.user
    assert_equal @chat, message.chat

    assert_redirected_to account_chat_path(@account, @chat)
  end

  test "a failure after the send committed still reports it sent" do
    assert_difference "Message.count", 1 do
      ModerateMessageJob.stub(:perform_later, ->(*) { raise "moderation queue down" }) do
        post account_chat_messages_path(@account, @chat), params: { message: { content: "Committed" } }
      end
    end

    assert_redirected_to account_chat_path(@account, @chat)
    assert_nil flash[:alert]
  end

  test "should trigger AI response job when message is created" do
    perform_enqueued_jobs do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Hello AI" }
      }
    end
    # This test verifies that the job runs without error
    # The actual job behavior is tested in the job tests
  end

  test "should handle single file attachment" do
    file = fixture_file_upload("test_image.png", "image/png")

    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Here's an image" },
        files: [ file ]
      }
    end

    message = Message.last
    assert message.attachments.attached?
    assert_equal 1, message.attachments.count
    assert_equal "test_image.png", message.attachments.first.filename.to_s
    assert_equal "image/png", message.attachments.first.content_type
    assert_redirected_to account_chat_path(@account, @chat)
  end

  test "should handle multiple file attachments" do
    image_file = fixture_file_upload("test_image.png", "image/png")
    pdf_file = fixture_file_upload("test_document.pdf", "application/pdf")
    audio_file = fixture_file_upload("test_audio.mp3", "audio/mpeg")

    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Multiple files attached" },
        files: [ image_file, pdf_file, audio_file ]
      }
    end

    message = Message.last
    assert message.attachments.attached?
    assert_equal 3, message.attachments.count

    filenames = message.attachments.map { |f| f.filename.to_s }
    assert_includes filenames, "test_image.png"
    assert_includes filenames, "test_document.pdf"
    assert_includes filenames, "test_audio.mp3"
    assert_redirected_to account_chat_path(@account, @chat)
  end

  test "a file with no caption is a message on the web too" do
    file = fixture_file_upload("test_image.png", "image/png")

    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "" },
        files: [ file ]
      }
    end

    message = Message.last
    assert_equal "", message.content.to_s
    assert_equal [ "test_image.png" ], message.attachments.map { |f| f.filename.to_s }
  end

  test "an empty message with no file is still refused on the web" do
    assert_no_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: { message: { content: "" } }
    end
  end

  test "should create message without files (backwards compatibility)" do
    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Message without files" }
      }
    end

    message = Message.last
    assert_not message.attachments.attached?
    assert_equal 0, message.attachments.count
    assert_equal "Message without files", message.content
    assert_redirected_to account_chat_path(@account, @chat)
  end

  test "should accept files outside the former type allowlist" do
    invalid_file = fixture_file_upload("test.exe", "application/x-msdownload")

    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Invalid file type" },
        files: [ invalid_file ]
      }
    end

    assert_response :redirect
    assert_equal "test.exe", Message.last.attachments.first.filename.to_s
  end

  test "should accept mixed file formats" do
    valid_file = fixture_file_upload("test_image.png", "image/png")
    invalid_file = fixture_file_upload("test.exe", "application/x-msdownload")

    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Mixed file types" },
        files: [ valid_file, invalid_file ]
      }
    end

    assert_response :redirect
    assert_equal 2, Message.last.attachments.count
  end

  test "should provide file metadata in JSON serialization" do
    file = fixture_file_upload("test_image.png", "image/png")

    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "File metadata test" },
        files: [ file ]
      }
    end

    message = Message.last

    # Test basic file attachment properties
    assert message.attachments.attached?
    assert_equal 1, message.attachments.count
    attached_file = message.attachments.first
    assert_equal "test_image.png", attached_file.filename.to_s
    assert_equal "image/png", attached_file.content_type
    assert attached_file.byte_size > 0
  end

  test "should provide attachment download paths for harnesses" do
    file = fixture_file_upload("test_image.png", "image/png")

    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "File paths test" },
        files: [ file ]
      }
    end

    message = Message.last
    file_paths = message.attachments_for_api.map { |file| file[:download_path] }

    assert_equal 1, file_paths.length
    assert file_paths.first.is_a?(String)
    assert file_paths.first.length > 0
  end

  test "should scope to current account" do
    # Create a completely separate user and account
    other_user = User.create!(
      email_address: "msgother@example.com"
    )
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(
      model_id: "gpt-4o",
      title: "Other Account Chat"
    )

    # Should return 404 when trying to post to a chat in a different account
    post account_chat_messages_path(@account, other_chat), params: {
      message: { content: "Should fail" }
    }
    assert_response :not_found
  end

  test "should require authentication" do
    delete logout_path

    post account_chat_messages_path(@account, @chat), params: {
      message: { content: "Should fail" }
    }
    assert_response :redirect
  end

  test "should require content" do
    assert_no_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "" }
      }
      # Validation errors redirect back to the chat with an error message
      assert_response :redirect
    end
  end

  test "should require content for JSON requests" do
    assert_no_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "" }
      }, as: :json
      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"], "Content can't be blank"
    end
  end

  test "should handle Inertia requests properly" do
    assert_difference "Message.count", 1 do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Hello from Inertia" }
      }, headers: {
        "X-Inertia" => "true",
        "X-Inertia-Version" => "1.0"
      }
      assert_response :redirect
      assert_redirected_to account_chat_path(@account, @chat)
    end

    assert_equal "Hello from Inertia", Message.last.content
    assert_equal @user, Message.last.user
    assert_equal "user", Message.last.role
  end

  test "should handle first message in a new chat" do
    # Create a new empty chat
    new_chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "New Empty Chat"
    )
    assert_equal 0, new_chat.messages.count

    # Send the first message
    assert_difference "Message.count" do
      post account_chat_messages_path(@account, new_chat), params: {
        message: { content: "First message in new chat" }
      }
    end

    message = Message.last
    assert_equal "First message in new chat", message.content
    assert_equal "user", message.role
    assert_equal @user, message.user
    assert_equal new_chat, message.chat

    assert_redirected_to account_chat_path(@account, new_chat)
  end

  test "should touch chat when message is created" do
    original_updated_at = @chat.updated_at

    # Wait a moment to ensure different timestamp
    sleep 0.1

    post account_chat_messages_path(@account, @chat), params: {
      message: { content: "Touch test" }
    }

    @chat.reload
    assert @chat.updated_at > original_updated_at
  end

  # Edit Last Message feature tests

  test "updates message content" do
    message = @chat.messages.create!(user: @user, role: "user", content: "Original")

    patch message_path(message), params: { message: { content: "Updated content" } }

    assert_response :ok
    assert_equal "Updated content", message.reload.content
  end

  test "can edit message even with subsequent messages" do
    message = @chat.messages.create!(user: @user, role: "user", content: "Original")
    @chat.messages.create!(role: "assistant", content: "Response")

    patch message_path(message), params: { message: { content: "Updated" } }

    assert_response :ok
    assert_equal "Updated", message.reload.content
  end

  test "cannot edit another user's message" do
    other_user = User.create!(email_address: "editother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    message = @chat.messages.create!(user: other_user, role: "user", content: "Their message")

    patch message_path(message), params: { message: { content: "Hacked" } }

    assert_response :forbidden
  end

  test "cannot edit assistant messages" do
    message = @chat.messages.create!(role: "assistant", content: "AI response")

    patch message_path(message), params: { message: { content: "Modified" } }

    assert_response :forbidden
  end

  test "update scopes to current account" do
    other_user = User.create!(email_address: "updateother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(model_id: "gpt-4o")
    other_message = other_chat.messages.create!(user: other_user, role: "user", content: "Their message")

    patch message_path(other_message), params: { message: { content: "Hacked" } }

    assert_response :not_found
  end

  test "update requires authentication" do
    message = @chat.messages.create!(user: @user, role: "user", content: "Original")

    delete logout_path

    patch message_path(message), params: { message: { content: "Updated" } }
    assert_response :redirect
  end

  # Delete Message feature tests

  test "deletes message by discarding it" do
    message = @chat.messages.create!(user: @user, role: "user", content: "To be deleted")

    assert_no_difference "Message.count" do
      assert_difference "Message.kept.count", -1 do
        delete message_path(message), as: :json
      end
    end

    assert_response :ok
    assert message.reload.discarded?
    assert_equal "To be deleted", message.content
  end

  test "deleting an already-deleted message is a no-op" do
    message = @chat.messages.create!(user: @user, role: "user", content: "Twice")
    delete message_path(message), as: :json
    revision = message.reload.revision

    assert_no_difference "AuditLog.count" do
      delete message_path(message), as: :json
    end

    assert_response :ok
    assert_equal revision, message.reload.revision
  end

  test "a deleted message cannot be edited" do
    message = @chat.messages.create!(user: @user, role: "user", content: "Gone")
    message.discard!

    patch message_path(message), params: { message: { content: "Back" } }, as: :json

    assert_response :not_found
    assert_equal "Gone", message.reload.content
  end

  test "can delete message even with subsequent messages" do
    message = @chat.messages.create!(user: @user, role: "user", content: "Original")
    @chat.messages.create!(role: "assistant", content: "Response")

    assert_difference "Message.kept.count", -1 do
      delete message_path(message), as: :json
    end

    assert_response :ok
  end

  test "cannot delete another user's message" do
    other_user = User.create!(email_address: "deleteother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    message = @chat.messages.create!(user: other_user, role: "user", content: "Their message")

    assert_no_difference "Message.kept.count" do
      delete message_path(message), as: :json
    end

    assert_response :forbidden
  end

  test "cannot delete assistant messages" do
    message = @chat.messages.create!(role: "assistant", content: "AI response")

    assert_no_difference "Message.kept.count" do
      delete message_path(message), as: :json
    end

    assert_response :forbidden
  end

  test "destroy scopes to current account" do
    other_user = User.create!(email_address: "destroyother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(model_id: "gpt-4o")
    other_message = other_chat.messages.create!(user: other_user, role: "user", content: "Their message")

    assert_no_difference "Message.kept.count" do
      delete message_path(other_message), as: :json
    end

    assert_response :not_found
  end

  test "destroy requires authentication" do
    message = @chat.messages.create!(user: @user, role: "user", content: "Original")

    delete logout_path

    delete message_path(message), as: :json
    assert_response :redirect
  end

  # Audit logging tests

  test "update creates audit log" do
    message = @chat.messages.create!(user: @user, role: "user", content: "Original")

    assert_difference "AuditLog.count", 1 do
      patch message_path(message), params: { message: { content: "Updated content" } }
    end

    assert_response :ok
    audit = AuditLog.last
    assert_equal "update_message", audit.action
    assert_equal message, audit.auditable
    assert_equal @user, audit.user
    assert_equal "Original", audit.data["old_content"]
    assert_equal "Updated content", audit.data["new_content"]
  end

  test "destroy creates audit log" do
    message = @chat.messages.create!(user: @user, role: "user", content: "To be deleted")

    assert_difference "AuditLog.count", 1 do
      delete message_path(message), as: :json
    end

    assert_response :ok
    audit = AuditLog.last
    assert_equal "delete_message", audit.action
    assert_equal @user, audit.user
    assert_equal "To be deleted", audit.data["content"]
  end

  # Site admin tests

  test "site admin can edit another user's message" do
    # Create message from regular user
    other_user = User.create!(email_address: "admintestreg@example.com")
    other_user.profile.update!(first_name: "Regular", last_name: "User")
    message = @chat.messages.create!(user: other_user, role: "user", content: "Regular user message")

    # Log out and log in as site admin
    delete logout_path
    admin_user = users(:site_admin_user)
    post login_path, params: { email_address: admin_user.email_address, password: "password123" }

    patch message_path(message), params: { message: { content: "Admin edited" } }

    assert_response :ok
    assert_equal "Admin edited", message.reload.content
  end

  test "site admin can delete another user's message" do
    # Create message from regular user
    other_user = User.create!(email_address: "admintestreg2@example.com")
    other_user.profile.update!(first_name: "Regular", last_name: "User")
    message = @chat.messages.create!(user: other_user, role: "user", content: "To be admin deleted")

    # Log out and log in as site admin
    delete logout_path
    admin_user = users(:site_admin_user)
    post login_path, params: { email_address: admin_user.email_address, password: "password123" }

    assert_difference "Message.kept.count", -1 do
      delete message_path(message), as: :json
    end

    assert_response :ok
  end

  # Auto-trigger mentioned agents tests

  test "should auto-trigger mentioned agents in group chat" do
    agent = @account.agents.create!(name: "Grok", system_prompt: "Test", runtime: "external")
    group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    group_chat.agent_ids = [ agent.id ]
    group_chat.save!

    assert_enqueued_with(job: MessageDispatchJob) do
      post account_chat_messages_path(@account, group_chat), params: {
        message: { content: "Hey @Grok, what do you think?" }
      }
    end
    assert_equal [ agent.id ], group_chat.messages.last.message_dispatch.target_agent_ids
  end

  test "should not auto-trigger when no agents mentioned in group chat" do
    agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
    group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    group_chat.agent_ids = [ agent.id ]
    group_chat.save!

    assert_no_enqueued_jobs(only: MessageDispatchJob) do
      post account_chat_messages_path(@account, group_chat), params: {
        message: { content: "Hello everyone" }
      }
    end
    assert_nil group_chat.messages.last.message_dispatch
  end

  test "should not enqueue AiResponseJob for group chat" do
    agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
    group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    group_chat.agent_ids = [ agent.id ]
    group_chat.save!

    assert_no_enqueued_jobs(only: AiResponseJob) do
      post account_chat_messages_path(@account, group_chat), params: {
        message: { content: "Hey @Grok, what do you think?" }
      }
    end
  end

  # Audio recording attachment tests

  test "creates message with audio_recording when audio_signed_id present" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("fake audio data"),
      filename: "recording.webm",
      content_type: "audio/webm"
    )

    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Voice message" },
        audio_signed_id: blob.signed_id
      }
    end

    message = Message.last
    assert message.audio_recording.attached?
    assert_equal "recording.webm", message.audio_recording.filename.to_s
  end

  test "sets audio_source true when audio_signed_id present" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("fake audio data"),
      filename: "recording.webm",
      content_type: "audio/webm"
    )

    post account_chat_messages_path(@account, @chat), params: {
      message: { content: "Voice message" },
      audio_signed_id: blob.signed_id
    }

    message = Message.last
    assert message.audio_source
  end

  test "creates normal message without audio when no audio_signed_id" do
    post account_chat_messages_path(@account, @chat), params: {
      message: { content: "Regular message" }
    }

    message = Message.last
    assert_not message.audio_recording.attached?
    assert_not message.audio_source
  end

  test "handles invalid audio_signed_id gracefully" do
    assert_difference "Message.count" do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Message with bad audio" },
        audio_signed_id: "invalid-signed-id-value"
      }
    end

    message = Message.last
    assert_equal "Message with bad audio", message.content
    assert_not message.audio_recording.attached?
    assert_not message.audio_source
  end

  # #94 B, step 4b-ii: acceptance (message, audit, wake intent) is one
  # transaction; the wake is enqueued after it commits.
  test "a failed wake enqueue after acceptance is still a created send, left pending for the sweeper" do
    chat = mention_chat
    MessageDispatchJob.stub(:perform_later, ->(*) { raise "synthetic enqueue failure" }) do
      post account_chat_messages_path(@account, chat), params: { message: { content: "Hello @Grok" } }, as: :json
    end

    assert_response :created
    message = chat.messages.last
    assert AuditLog.where(action: "create_message", auditable: message).exists?
    assert_equal "pending", message.message_dispatch.status
  end

  test "a failing create audit saves and wakes nothing" do
    chat = mention_chat
    dispatched = false
    assert_no_difference [ "Message.count", "MessageDispatch.count" ] do
      AuditLog.stub(:create!, ->(**) { raise "synthetic audit failure" }) do
        MessageDispatchJob.stub(:perform_later, ->(*) { dispatched = true }) do
          post account_chat_messages_path(@account, chat), params: { message: { content: "Hello @Grok" } }, as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    assert_not dispatched
  end

  test "a mention while live activity is off is refused truthfully and saves nothing" do
    chat = mention_chat
    with_live_activity_off do
      assert_no_difference [ "Message.count", "MessageDispatch.count", "AuditLog.count" ] do
        post account_chat_messages_path(@account, chat), params: { message: { content: "Hello @Grok" } }, as: :json
      end
      assert_response :service_unavailable
      assert_match "not sent", response.parsed_body["errors"].first

      assert_difference "Message.count" do
        post account_chat_messages_path(@account, chat), params: { message: { content: "No mention" } }, as: :json
      end
      assert_response :created
    end
  end

  private

  def with_live_activity_off
    previous = ENV["SOULSHOUSE_LIVE_ACTIVITY"]
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = "0"
    yield
  ensure
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = previous
  end

  def mention_chat
    agent = @account.agents.create!(name: "Grok", system_prompt: "Test", runtime: "external")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!
    chat
  end

end
