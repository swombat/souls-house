# RubyLLM Streaming Documentation

Response streaming allows real-time display of AI responses as they're generated, providing a better user experience for longer responses.

## Version Information
- Documentation source: https://rubyllm.com/streaming/
- Fetched: 2025-10-05

## Key Concepts

- **Streaming**: Real-time display of AI responses as they're generated
- **Chunks**: Individual response fragments containing content and metadata
- **Block-based processing**: Using Ruby blocks to handle streaming chunks
- **ActionCable integration**: Broadcasting chunks to WebSocket connections
- **Error handling**: Graceful handling of streaming failures

## Basic Streaming Setup

### Simple Streaming Example

```ruby
chat = RubyLLM.chat

chat.ask "Write a short story" do |chunk|
  print chunk.content # Prints response fragments incrementally
end
```

### Chunk Structure

Each streaming chunk (`RubyLLM::Chunk`) contains:
- `content`: Text fragment (string)
- `role`: Always `:assistant`
- `tool_calls`: Partial tool call information
- `input_tokens`: Total input tokens used
- `output_tokens`: Cumulative output tokens generated

## Rails Integration with ActionCable

### Streaming with Turbo Streams

```ruby
class ChatStreamJob < ApplicationJob
  def perform(chat_id, user_message, stream_target_id)
    chat = Chat.find(chat_id)
    full_response = ""

    # Initial loading state
    Turbo::StreamsChannel.broadcast_replace_to(
      "chat_#{chat.id}",
      target: stream_target_id,
      partial: "messages/streaming_message",
      locals: { content: "Thinking..." }
    )

    # Stream response chunks
    chat.ask(user_message) do |chunk|
      full_response << (chunk.content || "")
      Turbo::StreamsChannel.broadcast_replace_to(
        "chat_#{chat.id}",
        target: stream_target_id,
        partial: "messages/streaming_message",
        locals: { content: full_response }
      )
    end

    # Finalize the message
    Message.create!(
      chat: chat,
      role: :assistant,
      content: full_response
    )
  end
end
```

### Controller Implementation

```ruby
class ChatsController < ApplicationController
  def send_message
    @chat = Chat.find(params[:id])
    user_message = params[:message]

    # Create user message
    @chat.messages.create!(role: :user, content: user_message)

    # Generate unique stream target ID
    stream_target_id = "message_#{SecureRandom.uuid}"

    # Start streaming job
    ChatStreamJob.perform_later(@chat.id, user_message, stream_target_id)

    # Return the target ID for frontend to subscribe to
    render json: { stream_target_id: stream_target_id }
  end
end
```

### Frontend Turbo Stream Subscription

```javascript
// Subscribe to chat stream
const source = new EventSource(`/chats/${chatId}/stream`);
source.addEventListener('turbo-stream', (event) => {
  // Turbo will automatically handle the stream updates
});
```

## Server-Sent Events (SSE) Integration

### Sinatra Example

```ruby
get '/stream_chat' do
  content_type 'text/event-stream'
  headers 'Cache-Control' => 'no-cache'

  stream(:keep_open) do |out|
    chat = RubyLLM.chat

    begin
      chat.ask(params[:prompt]) do |chunk|
        if chunk.content
          data = {
            content: chunk.content,
            tokens: chunk.output_tokens
          }
          out << "data: #{data.to_json}\n\n"
        end
      end

      # Send completion signal
      out << "data: {\"done\": true}\n\n"
    rescue => e
      out << "data: {\"error\": \"#{e.message}\"}\n\n"
    ensure
      out.close
    end
  end
end
```

### Rails SSE Controller

```ruby
class StreamController < ApplicationController
  include ActionController::Live

  def chat_stream
    response.headers['Content-Type'] = 'text/event-stream'
    response.headers['Cache-Control'] = 'no-cache'

    chat = RubyLLM.chat

    begin
      chat.ask(params[:prompt]) do |chunk|
        if chunk.content
          data = {
            content: chunk.content,
            input_tokens: chunk.input_tokens,
            output_tokens: chunk.output_tokens
          }
          response.stream.write("data: #{data.to_json}\n\n")
        end
      end
    rescue IOError
      # Client disconnected
    ensure
      response.stream.close
    end
  end
end
```

## Error Handling in Streams

### Comprehensive Error Handling

```ruby
def stream_with_error_handling(chat, prompt, &block)
  begin
    chat.ask(prompt) do |chunk|
      begin
        yield chunk if block_given?
      rescue => chunk_error
        Rails.logger.error "Chunk processing error: #{chunk_error.message}"
        # Continue streaming despite chunk errors
      end
    end
  rescue RubyLLM::AuthenticationError => e
    handle_auth_error(e)
  rescue RubyLLM::RateLimitError => e
    handle_rate_limit_error(e)
  rescue RubyLLM::BadRequestError => e
    handle_bad_request_error(e)
  rescue StandardError => e
    Rails.logger.error "Streaming error: #{e.message}"
    raise
  end
end

private

def handle_auth_error(error)
  broadcast_error("Authentication failed. Please check API credentials.")
end

def handle_rate_limit_error(error)
  broadcast_error("Rate limit exceeded. Please try again later.")
end

def handle_bad_request_error(error)
  broadcast_error("Invalid request. Please check your input.")
end

def broadcast_error(message)
  Turbo::StreamsChannel.broadcast_replace_to(
    "chat_#{@chat.id}",
    target: @stream_target_id,
    partial: "messages/error_message",
    locals: { error: message }
  )
end
```

## Streaming with Attachments

### Handling File Uploads in Streams

```ruby
class DocumentChatJob < ApplicationJob
  def perform(document_id, question, stream_target_id)
    document = Document.find(document_id)
    full_response = ""

    # Create chat with document context
    chat = RubyLLM.chat
    chat.context = document.content

    # Stream response
    chat.ask(question) do |chunk|
      full_response << (chunk.content || "")

      # Broadcast with document reference
      Turbo::StreamsChannel.broadcast_replace_to(
        "document_chat_#{document.id}",
        target: stream_target_id,
        partial: "documents/streaming_response",
        locals: {
          content: full_response,
          document: document,
          tokens_used: chunk.output_tokens
        }
      )
    end

    # Save the conversation
    DocumentConversation.create!(
      document: document,
      question: question,
      answer: full_response,
      tokens_used: chat.total_tokens
    )
  end
end
```

### Image Analysis Streaming

```ruby
def stream_image_analysis(image_path, prompt)
  chat = RubyLLM.chat

  # Attach image to chat
  chat.attach(image_path)

  response_content = ""

  chat.ask(prompt) do |chunk|
    response_content << (chunk.content || "")

    # Broadcast analysis progress
    ActionCable.server.broadcast(
      "image_analysis_#{current_user.id}",
      {
        content: response_content,
        progress: calculate_progress(chunk.output_tokens),
        image_url: url_for(image_path)
      }
    )
  end

  response_content
end

private

def calculate_progress(tokens)
  # Estimate progress based on token count
  # This is approximate since we don't know total length
  [tokens / 500.0 * 100, 100].min
end
```

## Performance Optimization

### Background Job Processing

```ruby
class OptimizedChatStreamJob < ApplicationJob
  queue_as :streaming

  def perform(chat_id, message, stream_target_id)
    chat = Chat.find(chat_id)
    response_chunks = []

    # Use connection pooling
    RubyLLM.configure do |config|
      config.connection_pool_size = 5
      config.request_timeout = 30
    end

    chat.ask(message) do |chunk|
      response_chunks << chunk.content if chunk.content

      # Batch small chunks for efficiency
      if response_chunks.size >= 3 || chunk.content&.length.to_i > 50
        broadcast_chunks(chat.id, stream_target_id, response_chunks.join)
        response_chunks.clear
      end
    end

    # Send any remaining chunks
    unless response_chunks.empty?
      broadcast_chunks(chat.id, stream_target_id, response_chunks.join)
    end
  end

  private

  def broadcast_chunks(chat_id, target_id, content)
    Turbo::StreamsChannel.broadcast_append_to(
      "chat_#{chat_id}",
      target: target_id,
      partial: "messages/chunk",
      locals: { content: content }
    )
  end
end
```

### Memory Management

```ruby
class MemoryEfficientStreaming
  MAX_RESPONSE_LENGTH = 10_000
  CHUNK_BUFFER_SIZE = 100

  def stream_with_limits(chat, prompt)
    response_length = 0
    chunk_buffer = []

    chat.ask(prompt) do |chunk|
      # Prevent memory bloat
      if response_length + chunk.content.length > MAX_RESPONSE_LENGTH
        broadcast_error("Response too long, truncating...")
        break
      end

      chunk_buffer << chunk.content
      response_length += chunk.content.length

      # Flush buffer periodically
      if chunk_buffer.size >= CHUNK_BUFFER_SIZE
        yield chunk_buffer.join
        chunk_buffer.clear
      end
    end

    # Flush remaining buffer
    yield chunk_buffer.join unless chunk_buffer.empty?
  end
end
```

## Important Considerations

### Stream Lifecycle Management
- Always handle client disconnections gracefully
- Implement timeouts for long-running streams
- Clean up resources when streams complete or fail
- Monitor token usage to prevent runaway costs

### WebSocket vs SSE
- **ActionCable (WebSocket)**: Better for bidirectional communication, requires more setup
- **Server-Sent Events**: Simpler implementation, unidirectional, works well with Turbo Streams

### Security Considerations
- Validate user permissions before starting streams
- Sanitize streamed content before broadcasting
- Implement rate limiting on streaming endpoints
- Log streaming activities for audit purposes

### Testing Streaming
```ruby
# RSpec example for testing streaming
RSpec.describe ChatStreamJob do
  it "streams response chunks" do
    chat = create(:chat)
    chunks = []

    # Mock streaming behavior
    allow(RubyLLM).to receive(:chat).and_return(double(
      ask: proc { |prompt, &block|
        ["Hello", " world", "!"].each { |chunk| block.call(double(content: chunk)) }
      }
    ))

    # Capture broadcasts
    expect {
      ChatStreamJob.perform_now(chat.id, "Hello", "target_123")
    }.to have_broadcasted_to("chat_#{chat.id}")
  end
end
```

## Related Documentation
- [RubyLLM Chat Documentation](https://rubyllm.com/chat/)
- [Rails ActionCable Guide](https://guides.rubyonrails.org/action_cable_overview.html)
- [Turbo Streams Reference](https://turbo.hotwired.dev/handbook/streams)