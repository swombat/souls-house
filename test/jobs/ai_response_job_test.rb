require "test_helper"
require "ostruct"

class AiResponseJobTest < ActiveJob::TestCase

  setup do
    # Create test data instead of using fixtures
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Test Conversation"
    )
    @user_message = @chat.messages.create!(
      content: "Hello, how are you?",
      role: "user",
      user: @user
    )
  end

  test "streams content and finalizes message" do
    # Create the AI message first (as the real flow would)
    ai_message = @chat.messages.create!(
      role: "assistant",
      content: ""
    )

    # Mock the streaming response
    mock_chunks = [
      OpenStruct.new(content: "Hello"),
      OpenStruct.new(content: ", "),
      OpenStruct.new(content: "how can I help?")
    ]

    # Override the complete method for this test
    @chat.define_singleton_method(:complete) do |&block|
      # Simulate on_new_message callback
      @on_new_message_callback&.call

      # Simulate streaming chunks
      mock_chunks.each { |chunk| block.call(chunk) }

      # Simulate on_end_message callback
      final_message = OpenStruct.new(
        content: "Hello, how can I help?",
        model_id: "test-model",
        input_tokens: 10,
        output_tokens: 15
      )
      @on_end_message_callback&.call(final_message)
    end

    @chat.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = block
    end

    @chat.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    @chat.define_singleton_method(:on_tool_call) do |&block|
      @on_tool_call_callback = block
    end

    # Run the job
    AiResponseJob.perform_now(@chat)

    # Check the final result
    ai_message.reload
    assert_equal "Hello, how can I help?", ai_message.content
    assert_not ai_message.streaming?  # Should be false after finalization
    assert_equal "test-model", ai_message.model_id_string
    assert_equal 10, ai_message.input_tokens
    assert_equal 15, ai_message.output_tokens
  end

  test "handles empty chunks gracefully" do
    mock_chunks = [
      OpenStruct.new(content: nil),
      OpenStruct.new(content: "Valid content"),
      OpenStruct.new(content: "")
    ]

    # Override the complete method for this test
    @chat.define_singleton_method(:complete) do |&block|
      @on_new_message_callback&.call
      mock_chunks.each { |chunk| block.call(chunk) }

      final_message = OpenStruct.new(
        content: "Valid content",
        model_id: "test-model",
        input_tokens: 5,
        output_tokens: 10
      )
      @on_end_message_callback&.call(final_message)
    end

    @chat.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = block
    end

    @chat.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    @chat.define_singleton_method(:on_tool_call) do |&block|
      @on_tool_call_callback = block
    end

    AiResponseJob.perform_now(@chat)

    ai_message = Message.last
    assert_equal "Valid content", ai_message.content
  end

  test "job is enqueued properly" do
    assert_enqueued_with(job: AiResponseJob, args: [ @chat ]) do
      AiResponseJob.perform_later(@chat)
    end
  end

  test "sets streaming to false in finalize_message" do
    mock_chunks = [
      OpenStruct.new(content: "Hello"),
      OpenStruct.new(content: ", "),
      OpenStruct.new(content: "how can I help?")
    ]

    # Override the complete method to simulate streaming and finalization
    @chat.define_singleton_method(:complete) do |&block|
      # Simulate on_new_message callback
      @on_new_message_callback&.call

      # Simulate streaming chunks
      mock_chunks.each { |chunk| block.call(chunk) }

      # Simulate on_end_message callback
      final_message = OpenStruct.new(
        content: "Hello, how can I help?",
        model_id: "test-model",
        input_tokens: 10,
        output_tokens: 15
      )
      @on_end_message_callback&.call(final_message)
    end

    # Mock callback registration
    @chat.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = block
    end

    @chat.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    @chat.define_singleton_method(:on_tool_call) do |&block|
      @on_tool_call_callback = block
    end

    AiResponseJob.perform_now(@chat)

    ai_message = Message.last
    assert_equal "Hello, how can I help?", ai_message.content
    assert_not ai_message.streaming?  # Should be false after finalization
  end

  test "handles job failure gracefully" do
    # Create an AI message that will be streaming
    ai_message = @chat.messages.create!(
      role: "assistant",
      content: "",
      streaming: true
    )

    # Override the complete method to raise an error
    @chat.define_singleton_method(:complete) do |&block|
      @on_new_message_callback&.call
      raise "Simulated error"
    end

    @chat.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = block
    end

    @chat.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    @chat.define_singleton_method(:on_tool_call) do |&block|
      @on_tool_call_callback = block
    end

    # The job should handle the error but still stop streaming
    assert_raises(RuntimeError, "Simulated error") do
      AiResponseJob.perform_now(@chat)
    end

    # The message should no longer be streaming after the error
    ai_message.reload
    assert_not ai_message.streaming?
  end

  test "handles messages with file attachments" do
    # Create a message with file attachments
    message_with_files = @chat.messages.create!(
      content: "Please analyze this image",
      role: "user",
      user: @user
    )

    # Mock file attachment
    file = Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/test_image.png"),
      "image/png"
    )
    message_with_files.attachments.attach(file)

    assert message_with_files.attachments.attached?, "File should be attached"

    # Test that file_paths_for_llm works
    file_paths = message_with_files.file_paths_for_llm
    assert_equal 1, file_paths.count
    assert file_paths.first.is_a?(String)

    # Mock the completion (files should be handled through message conversion)
    completion_options_used = nil
    @chat.define_singleton_method(:complete) do |**options, &block|
      completion_options_used = options
      @on_new_message_callback&.call

      # Simulate streaming
      chunk = OpenStruct.new(content: "I can see the image")
      block.call(chunk)

      # Simulate completion
      final_message = OpenStruct.new(
        content: "I can see the image you've shared",
        model_id: "test-model",
        input_tokens: 15,
        output_tokens: 20
      )
      @on_end_message_callback&.call(final_message)
    end

    chat = @chat # Capture for closure
    @chat.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = proc do
        # Create AI message like the real system would
        chat.messages.create!(role: "assistant", content: "", streaming: true)
        block&.call
      end
    end

    @chat.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    @chat.define_singleton_method(:on_tool_call) do |&block|
      @on_tool_call_callback = block
    end

    # Run the job
    AiResponseJob.perform_now(@chat)

    # Verify that completion was called (files handled through message conversion)
    assert_not_nil completion_options_used
    # Files should NOT be passed to complete - they're handled via to_llm message conversion
    assert_nil completion_options_used[:with]

    # Verify the response
    ai_message = @chat.messages.where(role: "assistant").last
    assert_equal "I can see the image you've shared", ai_message.content
  end

  test "handles messages without file attachments" do
    # Test the normal case without files
    completion_options_used = nil
    @chat.define_singleton_method(:complete) do |**options, &block|
      completion_options_used = options
      @on_new_message_callback&.call

      chunk = OpenStruct.new(content: "Hello")
      block.call(chunk)

      final_message = OpenStruct.new(
        content: "Hello there",
        model_id: "test-model",
        input_tokens: 5,
        output_tokens: 10
      )
      @on_end_message_callback&.call(final_message)
    end

    chat = @chat # Capture for closure
    @chat.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = proc do
        # Create AI message like the real system would
        chat.messages.create!(role: "assistant", content: "", streaming: true)
        block&.call
      end
    end

    @chat.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    @chat.define_singleton_method(:on_tool_call) do |&block|
      @on_tool_call_callback = block
    end

    # Run the job
    AiResponseJob.perform_now(@chat)

    # Verify that completion was called without file options
    assert_empty completion_options_used
  end

  test "raises error when passed a relation instead of a single chat" do
    # Simulate the error mentioned where someone passes Chat.latest instead of Chat.latest.first
    chat_relation = Chat.where(id: @chat.id) # This returns a relation, not a single object

    error = assert_raises(ArgumentError) do
      AiResponseJob.perform_now(chat_relation)
    end

    assert_match(/Expected a Chat object, got/, error.message)
    assert_match(/ActiveRecord_Relation/, error.message)
  end

  test "tracks tools_used when tool is invoked" do
    # Create chat with web access
    chat_with_tools = @account.chats.create!(
      model_id: "openrouter/auto",
      web_access: true
    )
    chat_with_tools.messages.create!(
      content: "Fetch https://example.com",
      role: "user",
      user: @user
    )

    # Track if on_tool_call was registered
    tool_callback_registered = false
    chat_with_tools.define_singleton_method(:on_tool_call) do |&block|
      tool_callback_registered = true
      @on_tool_call_callback = block
    end

    # Mock the completion flow with tool invocation
    chat_with_tools.define_singleton_method(:complete) do |&block|
      @on_new_message_callback&.call

      # Simulate tool invocation with tool_call object
      tool_call = OpenStruct.new(name: "WebTool", arguments: { action: "fetch", url: "https://example.com" })
      @on_tool_call_callback&.call(tool_call)

      chunk = OpenStruct.new(content: "I fetched the website")
      block.call(chunk)

      final_message = OpenStruct.new(
        content: "I fetched the website and found...",
        model_id: "test-model",
        input_tokens: 20,
        output_tokens: 30
      )
      @on_end_message_callback&.call(final_message)
    end

    chat_with_tools.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = proc do
        chat_with_tools.messages.create!(role: "assistant", content: "", streaming: true)
        block&.call
      end
    end

    chat_with_tools.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    # Run the job
    AiResponseJob.perform_now(chat_with_tools)

    # Verify tool callback was registered
    assert tool_callback_registered, "on_tool_call should be registered"

    # Verify tools_used was populated
    ai_message = chat_with_tools.messages.where(role: "assistant").last
    assert_not_nil ai_message, "AI message should be created"
    assert ai_message.tools_used.present?, "tools_used should be populated"
    assert_includes ai_message.tools_used, "https://example.com", "URL should be in tools_used"
  end

  test "handles multiple tool invocations" do
    # Create chat with web access
    chat_with_tools = @account.chats.create!(
      model_id: "openrouter/auto",
      web_access: true
    )
    chat_with_tools.messages.create!(
      content: "Fetch multiple URLs",
      role: "user",
      user: @user
    )

    # Mock on_tool_call registration
    chat_with_tools.define_singleton_method(:on_tool_call) do |&block|
      @on_tool_call_callback = block
    end

    # Mock the completion flow with multiple tool invocations
    chat_with_tools.define_singleton_method(:complete) do |&block|
      @on_new_message_callback&.call

      # Simulate multiple tool invocations
      tool_call1 = OpenStruct.new(name: "WebTool", arguments: { action: "fetch", url: "https://example.com" })
      tool_call2 = OpenStruct.new(name: "WebTool", arguments: { action: "fetch", url: "https://example.org" })
      @on_tool_call_callback&.call(tool_call1)
      @on_tool_call_callback&.call(tool_call2)

      chunk = OpenStruct.new(content: "I fetched both websites")
      block.call(chunk)

      final_message = OpenStruct.new(
        content: "I fetched both websites and found...",
        model_id: "test-model",
        input_tokens: 25,
        output_tokens: 35
      )
      @on_end_message_callback&.call(final_message)
    end

    chat_with_tools.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = proc do
        chat_with_tools.messages.create!(role: "assistant", content: "", streaming: true)
        block&.call
      end
    end

    chat_with_tools.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    # Run the job
    AiResponseJob.perform_now(chat_with_tools)

    # Verify tools_used contains the URLs
    ai_message = chat_with_tools.messages.where(role: "assistant").last
    assert_not_nil ai_message, "AI message should be created"
    assert ai_message.tools_used.present?, "tools_used should be populated"
    # Should contain both URLs since they're different
    assert_includes ai_message.tools_used, "https://example.com"
    assert_includes ai_message.tools_used, "https://example.org"
  end

  test "handles tool errors gracefully" do
    # Create chat with web access
    chat_with_tools = @account.chats.create!(
      model_id: "openrouter/auto",
      web_access: true
    )
    chat_with_tools.messages.create!(
      content: "Fetch invalid URL",
      role: "user",
      user: @user
    )

    # Mock on_tool_call registration
    chat_with_tools.define_singleton_method(:on_tool_call) do |&block|
      @on_tool_call_callback = block
    end

    # Mock the completion flow where tool returns an error
    chat_with_tools.define_singleton_method(:complete) do |&block|
      @on_new_message_callback&.call

      # Simulate tool invocation with error result
      tool_call = OpenStruct.new(name: "WebTool", arguments: { action: "fetch", url: "invalid" })
      @on_tool_call_callback&.call(tool_call)

      chunk = OpenStruct.new(content: "I encountered an error")
      block.call(chunk)

      final_message = OpenStruct.new(
        content: "I encountered an error fetching the URL",
        model_id: "test-model",
        input_tokens: 15,
        output_tokens: 20
      )
      @on_end_message_callback&.call(final_message)
    end

    chat_with_tools.define_singleton_method(:on_new_message) do |&block|
      @on_new_message_callback = proc do
        chat_with_tools.messages.create!(role: "assistant", content: "", streaming: true)
        block&.call
      end
    end

    chat_with_tools.define_singleton_method(:on_end_message) do |&block|
      @on_end_message_callback = block
    end

    # Run the job - should not raise an error
    assert_nothing_raised do
      AiResponseJob.perform_now(chat_with_tools)
    end

    # Verify the message was created
    ai_message = chat_with_tools.messages.where(role: "assistant").last
    assert_not_nil ai_message, "AI message should be created"
    assert_equal "I encountered an error fetching the URL", ai_message.content
    # Tool should still be tracked even if it errored
    assert_includes ai_message.tools_used, "invalid"
  end

  test "retired model-chat web access does not expose tools" do
    chat_with_tools = @account.chats.create!(
      model_id: "openrouter/auto",
      web_access: true
    )

    assert chat_with_tools.respond_to?(:available_tools)
    assert_empty chat_with_tools.available_tools
  end

end
