require "test_helper"
require "zip"
require "zip"

class MessageTest < ActiveSupport::TestCase

  def setup
    @user = User.create!(
      email_address: "test#{SecureRandom.hex(4)}@example.com",
      password: "password123"
    )
    @user.profile.update!(first_name: "Test", last_name: "User")
    @account = @user.personal_account
    @chat = Chat.create!(account: @account)
  end

  test "belongs to chat with touch" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )
    chat_updated_at = @chat.updated_at

    message.touch

    # Chat should have been touched too
    assert @chat.reload.updated_at > chat_updated_at
  end

  test "belongs to user optionally" do
    user_message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "User message"
    )
    ai_message = @chat.messages.create!(
      role: "assistant",
      content: "AI message"
    )

    assert_equal @user, user_message.user
    assert_nil ai_message.user
  end

  test "has many attached files" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )
    assert message.respond_to?(:attachments)
  end

  test "accepts audio MIME types emitted by Marcel" do
    message = @chat.messages.build(user: @user, role: "user", content: "Audio")
    file = Struct.new(:content_type, :filename)

    {
      "audio/mpeg" => "recording.mp3",
      "audio/vnd.wave" => "recording.wav",
      "audio/x-flac" => "recording.flac",
      "audio/mp4" => "recording.m4a",
      "audio/vorbis" => "recording.ogg",
      "audio/ogg" => "recording.oga",
      "audio/opus" => "recording.opus",
      "audio/webm" => "recording.webm",
      "video/webm" => "recording.webm"
    }.each do |content_type, filename|
      assert message.send(:acceptable_file_type?, file.new(content_type, filename)),
        "Expected #{filename} with #{content_type} to be accepted"
    end
  end

  test "accepts supported audio extensions when MIME detection varies" do
    message = @chat.messages.build(user: @user, role: "user", content: "Audio")
    file = Struct.new(:content_type, :filename)

    %w[mp3 wav flac m4a ogg oga opus webm].each do |extension|
      assert message.send(:acceptable_file_type?, file.new("application/octet-stream", "recording.#{extension}")),
        "Expected .#{extension} audio files to be accepted"
    end
  end

  test "validates role inclusion" do
    message = Message.new(
      chat: @chat,
      user: @user,
      content: "Test content"
    )

    message.role = "invalid"
    assert_not message.valid?
    assert_includes message.errors[:role], "is not included in the list"

    message.role = "user"
    assert message.valid?
  end

  test "validates content presence" do
    message = Message.new(
      chat: @chat,
      user: @user,
      role: "user"
    )

    message.content = ""
    assert_not message.valid?
    assert_includes message.errors[:content], "can't be blank"

    message.content = "Valid content"
    assert message.valid?
  end

  test "allows valid roles" do
    %w[user assistant system].each do |role|
      message = Message.create!(
        chat: @chat,
        user: (role == "user" ? @user : nil),
        role: role,
        content: "Test #{role} message"
      )
      assert message.persisted?
    end
  end

  test "includes required concerns" do
    assert Message.included_modules.include?(Broadcastable)
    assert Message.included_modules.include?(ObfuscatesId)
  end

  test "acts as message" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )
    assert_equal @chat, message.chat
    assert_not message.respond_to?(:to_llm)
  end

  test "preserves docx attachments for download without provider conversion" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Please review this document"
    )
    message.attachments.attach(
      io: StringIO.new(docx_file("A heading", "Document body text")),
      filename: "draft.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )

    assert_equal "Please review this document", message.reload.content
    assert_equal "draft.docx", message.attachments_for_api.first[:filename]
    assert message.attachments.first.download.start_with?("PK")
  end

  test "preserves legacy word bytes without provider conversion" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Please review this old document"
    )
    message.attachments.attach(
      io: StringIO.new("legacy word bytes"),
      filename: "draft.doc",
      content_type: "application/msword"
    )

    assert_equal "legacy word bytes", message.attachments.first.download
    assert_equal "draft.doc", message.attachments_for_api.first[:filename]
  end

  test "broadcasts to chat" do
    assert_equal [ :chat ], Message.broadcast_targets
  end

  test "completed? returns true for user messages" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )
    assert message.completed?
  end

  test "completed? returns true for completed assistant messages" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    assert message.completed?
  end

  test "completed? returns false for incomplete assistant messages" do
    # Build message without saving (since content validation would fail)
    message = @chat.messages.build(
      role: "assistant",
      content: ""
    )
    assert_not message.completed?
  end

  test "user_name returns user full name" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )
    assert_equal "Test User", message.user_name
  end

  test "user_name returns nil when no user" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    assert_nil message.user_name
  end

  test "user_avatar_url returns user avatar" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )
    # User avatar_url returns nil in test environment
    assert_nil message.user_avatar_url
  end

  test "created_at_formatted returns formatted time" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message",
      created_at: Time.parse("2024-01-15 14:30:00 UTC")
    )
    formatted = message.created_at_formatted
    assert_includes formatted, ":30"
    assert_includes formatted, "M" # AM or PM
  end

  test "content_html renders markdown" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "# Heading\n\nSome **bold** text and `code`"
    )

    html = message.content_html
    assert_includes html, "<h1>Heading</h1>"
    assert_includes html, "<strong>bold</strong>"
    assert_includes html, "<code>code</code>"
  end

  test "content_html handles nil content" do
    # Build message without saving (since content is required)
    message = @chat.messages.build(
      role: "assistant",
      content: nil
    )

    # Should not raise error
    html = message.content_html
    assert_equal "", html
  end

  test "content_html filters dangerous HTML" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "<script>alert('xss')</script>Safe content"
    )

    html = message.content_html
    assert_not_includes html, "<script>"
    assert_includes html, "Safe content"
  end

  test "as_json returns complete message data" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test **markdown**"
    )

    json = message.as_json

    assert_equal message.to_param, json["id"]
    assert_equal "user", json["role"]
    assert_includes json["content_html"], "<strong>markdown</strong>"
    assert_equal "Test User", json["user_name"]
    assert_nil json["user_avatar_url"]  # User avatar_url returns nil in test
    assert json["completed"]
    assert_nil json["error"]
    assert json["created_at_formatted"].present?
  end

  test "as_json handles assistant message with error" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "Failed response"
    )

    json = message.as_json

    assert_equal "assistant", json["role"]
    assert_nil json["user_name"]
    assert_nil json["user_avatar_url"]
    # With content, assistant messages are complete
    assert json["completed"]
    # We don't track errors in database yet
    assert_nil json["error"]
  end

  test "stream_content updates content and sets streaming" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "Initial"
    )

    assert_not message.streaming?

    # Test that stream_content works
    message.stream_content(" chunk")

    message.reload
    assert_equal "Initial chunk", message.content
    assert message.streaming?
  end

  test "stream_content only sets streaming true once" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "",
      streaming: true
    )

    # Should already be streaming
    assert message.streaming?

    message.stream_content(" more content")

    message.reload
    assert_equal " more content", message.content
    assert message.streaming?  # Should still be streaming
  end

  test "stop_streaming sets streaming to false" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "Final content",
      streaming: true
    )

    assert message.streaming?

    message.stop_streaming

    message.reload
    assert_not message.streaming?
  end

  test "stop_streaming does nothing if not streaming" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "Final content",
      streaming: false
    )

    # Should not be streaming
    assert_not message.streaming?

    message.stop_streaming

    message.reload
    assert_not message.streaming?  # Should still not be streaming
  end

  test "files_json returns empty array when no files attached" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )

    assert_equal [], message.files_json
  end

  test "API attachments are empty when no files attached" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )

    assert_equal [], message.attachments_for_api
  end

  test "validates file size limit" do
    message = @chat.messages.build(
      user: @user,
      role: "user",
      content: "Test with large file"
    )

    # Create a mock large blob
    large_blob = ActiveStorage::Blob.new(
      filename: "large.png",
      content_type: "image/png",
      byte_size: 51.megabytes
    )

    # Mock the attachments.attached? and attachments.each for validation
    message.attachments.define_singleton_method(:attached?) { true }
    message.attachments.define_singleton_method(:each) { |&block| block.call(large_blob) }

    assert_not message.valid?
    assert_includes message.errors.full_messages.join, "50MB"
  end

  test "validates file type" do
    message = @chat.messages.build(
      user: @user,
      role: "user",
      content: "Test with invalid file"
    )

    # Create a mock invalid file blob
    invalid_blob = ActiveStorage::Blob.new(
      filename: "malicious.exe",
      content_type: "application/x-msdownload",
      byte_size: 1024
    )

    # Mock the attachments.attached? and attachments.each for validation
    message.attachments.define_singleton_method(:attached?) { true }
    message.attachments.define_singleton_method(:each) { |&block| block.call(invalid_blob) }

    assert_not message.valid?
    assert_includes message.errors.full_messages.join, "file type not supported"
  end

  test "accepts valid file types" do
    message = @chat.messages.build(
      user: @user,
      role: "user",
      content: "Test with valid file"
    )

    valid_blob = ActiveStorage::Blob.new(
      filename: "image.png",
      content_type: "image/png",
      byte_size: 1024
    )

    # Mock the attachments.attached? and attachments.each for validation
    message.attachments.define_singleton_method(:attached?) { true }
    message.attachments.define_singleton_method(:each) { |&block| block.call(valid_blob) }

    # Should pass validation since the file is valid
    assert message.valid?
  end

  test "tools_used defaults to empty array" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )

    assert_equal [], message.tools_used
  end

  test "tools_used can store tool names" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response",
      tools_used: [ "Web fetch", "Calculator" ]
    )

    assert_equal [ "Web fetch", "Calculator" ], message.tools_used
  end

  test "used_tools? returns false when no tools used" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )

    assert_not message.used_tools?
  end

  test "used_tools? returns false when tools_used is empty" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response",
      tools_used: []
    )

    assert_not message.used_tools?
  end

  test "used_tools? returns true when tools were used" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response",
      tools_used: [ "Web fetch" ]
    )

    assert message.used_tools?
  end

  test "as_json includes tools_used" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response",
      tools_used: [ "Web fetch", "Calculator" ]
    )

    json = message.as_json

    assert_equal [ "Web fetch", "Calculator" ], json["tools_used"]
  end

  # Content moderation tests

  test "moderation_flagged? returns false when scores are nil" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.moderation_scores = nil
    assert_not message.moderation_flagged?
  end

  test "moderation_flagged? returns false when no scores meet threshold" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.moderation_scores = { "hate" => 0.3, "violence" => 0.2 }
    assert_not message.moderation_flagged?
  end

  test "moderation_flagged? returns true when any score meets threshold" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.moderation_scores = { "hate" => 0.5, "violence" => 0.2 }
    assert message.moderation_flagged?
  end

  test "moderation_flagged? returns true when score exceeds threshold" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.moderation_scores = { "hate" => 0.6, "violence" => 0.2 }
    assert message.moderation_flagged?
  end

  test "moderation_severity returns nil when not flagged" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.moderation_scores = { "hate" => 0.3 }
    assert_nil message.moderation_severity
  end

  test "moderation_severity returns :high for scores >= 0.8" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.moderation_scores = { "hate" => 0.85, "violence" => 0.2 }
    assert_equal :high, message.moderation_severity
  end

  test "moderation_severity returns :medium for scores 0.5-0.8" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.moderation_scores = { "hate" => 0.65, "violence" => 0.2 }
    assert_equal :medium, message.moderation_severity
  end

  test "moderation_severity returns :medium for score at exactly 0.5" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.moderation_scores = { "hate" => 0.5, "violence" => 0.2 }
    assert_equal :medium, message.moderation_severity
  end

  test "user message queues moderation on create" do
    assert_enqueued_with(job: ModerateMessageJob) do
      @chat.messages.create!(role: "user", content: "Test message", user: @user)
    end
  end

  test "assistant message does not queue moderation on create" do
    assert_no_enqueued_jobs(only: ModerateMessageJob) do
      @chat.messages.create!(role: "assistant", content: "Response")
    end
  end

  test "as_json includes moderation attributes when present" do
    message = @chat.messages.create!(
      role: "assistant",
      content: "AI response"
    )
    message.update!(moderation_scores: { "hate" => 0.85, "violence" => 0.1 })

    json = message.as_json

    assert json["moderation_flagged"]
    assert_equal :high, json["moderation_severity"]
    assert_equal({ "hate" => 0.85, "violence" => 0.1 }, json["moderation_scores"])
  end

  test "historical tool-shaped text is preserved and cannot be executed as a repair" do
    content = '[2026-01-25 18:48] {"memory_type":"journal","content":"Old"}Original'
    message = @chat.messages.create!(role: "assistant", content: content, agent: agents(:with_save_memory_tool))
    assert_equal content, message.reload.content
    assert_not message.respond_to?(:fix_hallucinated_tool_calls!)
    assert_not message.as_json.key?("fixable")
  end

  # Auto-reopen conversation for agents tests

  test "human message reopens closed agents in group chat" do
    agent = agents(:research_assistant)
    chat = @account.chats.new(
      title: "Group Chat",
      manual_responses: true,
      model_id: agent.model_id
    )
    chat.agent_ids = [ agent.id ]
    chat.save!
    chat_agent = chat.chat_agents.find_by(agent: agent)
    chat_agent.close_for_initiation!

    chat.messages.create!(role: "user", user: @user, content: "Hey there!")

    refute chat_agent.reload.closed_for_initiation?
  end

  test "agent message does not reopen closed agents" do
    agent = agents(:research_assistant)
    chat = @account.chats.new(
      title: "Group Chat",
      manual_responses: true,
      model_id: agent.model_id
    )
    chat.agent_ids = [ agent.id ]
    chat.save!
    chat_agent = chat.chat_agents.find_by(agent: agent)
    chat_agent.close_for_initiation!

    chat.messages.create!(role: "assistant", agent: agent, content: "I'm still here")

    assert chat_agent.reload.closed_for_initiation?
  end

  test "human message in non-group chat does not reopen agents" do
    # Non-manual-responses chat
    chat = @account.chats.create!(title: "Regular Chat", manual_responses: false)

    # No error raised when creating a message
    assert_nothing_raised do
      chat.messages.create!(role: "user", user: @user, content: "Hello")
    end
  end

  # Audio recording tests

  test "audio_source defaults to false" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )

    assert_equal false, message.audio_source
  end

  test "audio_url returns path when audio_recording attached" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Voice message"
    )

    message.audio_recording.attach(
      io: StringIO.new("fake audio data"),
      filename: "recording.webm",
      content_type: "audio/webm"
    )

    assert message.audio_recording.attached?
    url = message.audio_url
    assert url.present?
    assert url.start_with?("/rails/active_storage/blobs/")
  end

  test "audio_url returns nil when no audio_recording" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Text message"
    )

    assert_nil message.audio_url
  end

  test "recorded audio retains its downloadable bytes" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Voice message"
    )

    message.audio_recording.attach(
      io: StringIO.new("fake audio data"),
      filename: "recording.webm",
      content_type: "audio/webm"
    )

    assert_equal "fake audio data", message.audio_recording.download
  end

  test "recorded audio is absent when no audio_recording" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Text message"
    )

    assert_not message.audio_recording.attached?
  end

  test "as_json includes audio_source and audio_url" do
    message = @chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )

    json = message.as_json

    assert_includes json.keys, "audio_source"
    assert_includes json.keys, "audio_url"
    assert_equal false, json["audio_source"]
    assert_nil json["audio_url"]
  end

  test "audio/webm is in ACCEPTABLE_FILE_TYPES" do
    assert_includes Message::ACCEPTABLE_FILE_TYPES[:audio], "audio/webm"
  end

  # Search scope tests

  test "search_in_account finds messages by content" do
    chat = @account.chats.create!(model_id: "openrouter/auto", title: "Search test")
    chat.messages.create!(content: "The quick brown fox", role: "user", user: @user)
    chat.messages.create!(content: "Jumped over the lazy dog", role: "assistant")

    results = Message.search_in_account(@account, "brown fox")
    assert_includes results.map(&:content), "The quick brown fox"
  end

  test "search_in_account is case insensitive" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    chat.messages.create!(content: "Hello World", role: "user", user: @user)

    results = Message.search_in_account(@account, "hello world")
    assert_equal 1, results.count
  end

  test "search_in_account excludes discarded chats" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    chat.messages.create!(content: "Should not find this", role: "user", user: @user)
    chat.discard!

    results = Message.search_in_account(@account, "Should not")
    assert_empty results
  end

  test "search_in_account excludes tool and system messages" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    chat.messages.create!(content: "system instructions", role: "system", skip_content_validation: true)
    chat.messages.create!(content: "tool output", role: "tool", skip_content_validation: true)

    results = Message.search_in_account(@account, "system")
    assert_empty results
  end

  test "search_in_account returns empty for blank query" do
    results = Message.search_in_account(@account, "")
    assert_empty results
  end

  private

  def docx_file(*paragraphs)
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
          #{paragraphs.map { |text| "<w:p><w:r><w:t>#{text}</w:t></w:r></w:p>" }.join}
        </w:body>
      </w:document>
    XML

    buffer = Zip::OutputStream.write_buffer do |archive|
      archive.put_next_entry("[Content_Types].xml")
      archive.write("<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'/>")
      archive.put_next_entry("word/document.xml")
      archive.write(xml)
    end

    buffer.string
  end

end
