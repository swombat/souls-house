# RubyLLM Chat Basics

## Version Information
- Documentation version: Latest (v1.7.0+)
- Source: https://rubyllm.com/chat/ and https://rubyllm.com/rails/
- Fetched: 2025-10-05

## Key Concepts

- **Chat Objects**: Create persistent conversations with AI models
- **Message Persistence**: Automatic saving of user and assistant messages
- **acts_as_chat**: Rails mixin that adds chat functionality to models
- **acts_as_message**: Rails mixin that enables message persistence
- **Conversation History**: Automatic maintenance of conversation context

## Implementation Guide

### 1. Basic Chat Creation

```ruby
# Simple in-memory chat
chat = RubyLLM.chat
response = chat.ask("Hello, how are you?")
puts response.content
```

### 2. Rails Integration with Persistence

#### Model Setup

```ruby
# app/models/chat.rb
class Chat < ApplicationRecord
  acts_as_chat  # Enables chat functionality
  belongs_to :user, optional: true
end

# app/models/message.rb
class Message < ApplicationRecord
  acts_as_message  # Enables message persistence
  validates :role, presence: true
  validates :chat, presence: true
end
```

#### Database Schema Requirements

Run the RubyLLM generator to create necessary migrations:

```bash
rails generate ruby_llm:install
rails db:migrate
```

This creates tables for:
- `chats` - Chat sessions
- `messages` - Individual messages
- `tool_calls` - Tool execution records
- `models` - AI model configurations

#### Creating Persistent Chats

```ruby
# Create a new chat
chat_record = Chat.create!(user: current_user)

# Send messages (automatically persisted)
response = chat_record.ask("What's the weather like?")

# Access conversation history
chat_record.messages.each do |message|
  puts "#{message.role}: #{message.content}"
end
```

### 3. Chat Configuration Options

```ruby
# Configure model and parameters
chat = RubyLLM.chat(
  model: "gpt-4",
  temperature: 0.7,
  system: "You are a helpful assistant."
)

# With Rails persistence
chat_record = Chat.create!(
  user: current_user,
  model: "claude-3-sonnet",
  system_prompt: "You are a coding assistant."
)
```

### 4. Message Management

#### Sending Messages

```ruby
# Simple message
response = chat.ask("Explain Ruby on Rails")

# Message with context
response = chat.ask("Continue the previous explanation")

# Alternative method
response = chat.say("Tell me about...")
```

#### Accessing Message History

```ruby
# Get all messages in a chat
messages = chat_record.messages.order(:created_at)

# Filter by role
user_messages = chat_record.messages.where(role: 'user')
assistant_messages = chat_record.messages.where(role: 'assistant')

# Most recent message
last_message = chat_record.messages.last
```

#### Message Attributes

```ruby
message = chat_record.messages.last
puts message.role        # 'user' or 'assistant'
puts message.content     # Message text content
puts message.created_at  # Timestamp
puts message.input_tokens    # Token count for input
puts message.output_tokens   # Token count for output
```

## API Reference

### Chat Methods

```ruby
# Basic chat creation
RubyLLM.chat(options = {})

# Send message and get response
chat.ask(message, options = {})
chat.say(message, options = {})

# Access conversation history
chat.messages
```

### Chat Options

```ruby
{
  model: "gpt-4",              # AI model to use
  temperature: 0.7,            # Response creativity (0.0-2.0)
  system: "System prompt",     # System instructions
  max_tokens: 1000,           # Maximum response length
  top_p: 0.9,                 # Nucleus sampling parameter
  frequency_penalty: 0.0,     # Reduce repetition
  presence_penalty: 0.0       # Encourage topic diversity
}
```

### Rails Model Methods

```ruby
# Chat model methods
chat_record.ask(message, options = {})
chat_record.messages
chat_record.user
chat_record.created_at

# Message model methods
message.chat
message.role
message.content
message.input_tokens
message.output_tokens
message.created_at
```

## Code Examples

### Basic Rails Controller Integration

```ruby
class ChatsController < ApplicationController
  def create
    @chat = current_user.chats.create!(
      system_prompt: params[:system_prompt]
    )
    redirect_to @chat
  end

  def show
    @chat = current_user.chats.find(params[:id])
    @messages = @chat.messages.order(:created_at)
  end

  def ask
    @chat = current_user.chats.find(params[:id])

    response = @chat.ask(params[:message])

    redirect_to @chat, notice: "Message sent successfully"
  rescue RubyLLM::Error => e
    redirect_to @chat, alert: "Error: #{e.message}"
  end
end
```

### Background Job Processing

```ruby
class ProcessChatMessageJob < ApplicationJob
  def perform(chat_id, message_content)
    chat = Chat.find(chat_id)

    begin
      response = chat.ask(message_content)

      # Broadcast update using Turbo
      broadcast_replace_to(
        chat,
        target: "messages",
        partial: "chats/messages",
        locals: { messages: chat.messages }
      )
    rescue RubyLLM::Error => e
      # Handle error and notify user
      Rails.logger.error "Chat error: #{e.message}"
    end
  end
end
```

### Service Object Pattern

```ruby
class ChatService
  def initialize(user, chat_params = {})
    @user = user
    @chat_params = chat_params
  end

  def create_chat
    @user.chats.create!(
      system_prompt: @chat_params[:system_prompt],
      model: @chat_params[:model] || "gpt-4"
    )
  end

  def send_message(chat, message_content)
    chat.ask(message_content)
  rescue RubyLLM::Error => e
    handle_error(e)
  end

  private

  def handle_error(error)
    Rails.logger.error "Chat service error: #{error.message}"
    raise ChatServiceError, error.message
  end
end
```

## Important Considerations

### Performance
- Messages are automatically persisted to database
- Consider using background jobs for long-running chat operations
- Implement proper pagination for chat history in UI

### Error Handling
- Wrap chat operations in rescue blocks for `RubyLLM::Error`
- API rate limits and network issues can cause failures
- Implement retry logic for transient failures

### Security
- Validate user permissions before accessing chats
- Sanitize user input to prevent injection attacks
- Consider implementing content moderation for user messages

### Memory Management
- Long conversations consume more tokens and memory
- Consider implementing conversation trimming for very long chats
- Monitor token usage to control costs

### Configuration Requirements

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  config.use_new_acts_as = true  # Recommended for v1.7.0+
end
```

## Related Documentation

- [Multi-Modal Conversations](multi-modal-conversations.md) - File and attachment handling
- [Structured Output](structured-output.md) - JSON responses and schemas
- [Token Usage](token-usage.md) - Token tracking and cost management
- [RubyLLM Streaming](https://rubyllm.com/streaming/) - Real-time responses
- [RubyLLM Tools](https://rubyllm.com/tools/) - Function calling and tools