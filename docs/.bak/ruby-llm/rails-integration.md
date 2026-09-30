# RubyLLM Rails Integration Documentation

## Version Information
- Documentation source: https://rubyllm.com/rails/
- Related sources: https://rubyllm.com/chat/, https://rubyllm.com/tools/, https://rubyllm.com/streaming/
- Fetched: 2025-10-05

## Key Concepts

### Core Rails Integration Features
- **Model Helpers**: `acts_as_chat`, `acts_as_message`, and `acts_as_tool_call` for seamless ActiveRecord integration
- **Automatic Persistence**: Conversations, messages, and tool calls are automatically saved to the database
- **Real-time Broadcasting**: Built-in Turbo Streams integration for live UI updates
- **ActiveStorage Support**: Seamless file attachment handling with automatic type detection
- **Model Registry**: Track model metadata and capabilities (v1.7.0+)
- **Background Processing**: ActiveJob integration for async AI operations

### Configuration Fundamentals
RubyLLM integrates with Rails through a simple configuration block and model helpers:

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  config.use_new_acts_as = true  # Enable v1.7.0+ features
end
```

## Implementation Guide

### Step 1: Database Setup

RubyLLM automatically generates migrations for the required tables:

```bash
rails generate ruby_llm:install
rails db:migrate
```

This creates tables for:
- **Chats**: Conversation containers
- **Messages**: Individual messages with content and attachments
- **ToolCalls**: Function calls and their results
- **Models**: Model metadata and capabilities (v1.7.0+)

### Step 2: Model Configuration

#### acts_as_chat Implementation

```ruby
class Chat < ApplicationRecord
  acts_as_chat

  # Optional associations
  belongs_to :user, optional: true
  belongs_to :organization, optional: true

  # Custom validations
  validates :title, presence: true, length: { maximum: 255 }

  # Scopes for filtering
  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
end
```

**Key acts_as_chat Features:**
- Automatically manages message associations
- Provides conversation context management
- Enables streaming capabilities
- Supports custom model configuration
- Handles empty message cleanup

**Available Methods:**
```ruby
chat = Chat.create(title: "AI Discussion")

# Start a conversation
response = chat.ask("What is Ruby on Rails?")

# Add system instructions
chat.with_instructions("You are a helpful Rails expert")
     .ask("Explain MVC pattern")

# Configure model and temperature
chat.with_model("gpt-4")
    .with_temperature(0.7)
    .ask("Creative writing prompt")

# Streaming responses
chat.ask("Long explanation") do |chunk|
  broadcast_to_user(chunk.content)
end
```

#### acts_as_message Implementation

```ruby
class Message < ApplicationRecord
  acts_as_message

  # Enable ActiveStorage for file attachments
  has_many_attached :files

  # Custom scopes
  scope :user_messages, -> { where(role: 'user') }
  scope :assistant_messages, -> { where(role: 'assistant') }
  scope :with_attachments, -> { joins(:files_attachments) }

  # Callbacks for processing
  after_create :process_attachments
  before_save :sanitize_content

  private

  def process_attachments
    # Custom attachment processing logic
    files.each do |file|
      AttachmentProcessorJob.perform_later(self, file)
    end
  end

  def sanitize_content
    # Content sanitization logic
    self.content = ActionController::Base.helpers.sanitize(content)
  end
end
```

**Message Structure and Attributes:**
```ruby
# Core message attributes
message.role       # 'user', 'assistant', 'system', 'tool'
message.content    # Text content
message.model      # AI model used for generation
message.tokens     # Token count information
message.metadata   # Additional structured data

# File attachment handling
message.files.attach(params[:files])  # Multiple file upload
message.files.each do |file|
  case file.content_type
  when /\Aimage/
    # Process image attachment
  when /\Aaudio/
    # Process audio attachment
  when /\Avideo/
    # Process video attachment
  when 'application/pdf'
    # Process PDF attachment
  end
end
```

**ATTACHMENT HANDLING - Critical Implementation Details:**

```ruby
class MessagesController < ApplicationController
  def create
    @message = current_chat.messages.build(message_params)

    # Handle file uploads
    if params[:files].present?
      @message.files.attach(params[:files])
    end

    if @message.save
      # Process AI response in background
      AiResponseJob.perform_later(@message.chat)

      # Broadcast new message via Turbo Streams
      broadcast_message(@message)
    end
  end

  private

  def message_params
    params.require(:message).permit(:content, :role, files: [])
  end

  def broadcast_message(message)
    broadcast_update_to(
      message.chat,
      target: "messages",
      partial: "messages/message",
      locals: { message: message }
    )
  end
end
```

**ActiveStorage Integration Patterns:**
```ruby
# In your view (Svelte component or ERB)
<%= form_with model: [@chat, @message], local: false do |f| %>
  <%= f.text_area :content, class: "textarea" %>
  <%= f.file_field :files, multiple: true,
                   accept: "image/*,audio/*,video/*,.pdf,.txt,.md" %>
  <%= f.submit "Send", class: "btn btn-primary" %>
<% end %>

# File validation
class Message < ApplicationRecord
  validate :acceptable_files

  private

  def acceptable_files
    return unless files.attached?

    files.each do |file|
      unless file.content_type.in?(%w[
        image/jpeg image/png image/gif image/webp
        audio/mpeg audio/wav audio/mp3
        video/mp4 video/webm
        application/pdf
        text/plain text/markdown
      ])
        errors.add(:files, "#{file.filename} is not a supported file type")
      end

      if file.byte_size > 50.megabytes
        errors.add(:files, "#{file.filename} is too large (max 50MB)")
      end
    end
  end
end
```

#### acts_as_tool_call Implementation

```ruby
class ToolCall < ApplicationRecord
  acts_as_tool_call

  # Associations
  belongs_to :message
  has_one :chat, through: :message

  # Validations
  validates :name, presence: true
  validates :arguments, presence: true

  # Callbacks
  after_create :execute_tool
  after_update :broadcast_result, if: :saved_change_to_result?

  private

  def execute_tool
    ToolExecutionJob.perform_later(self)
  end

  def broadcast_result
    broadcast_update_to(
      chat,
      target: "tool_call_#{id}",
      partial: "tool_calls/result",
      locals: { tool_call: self }
    )
  end
end
```

### Step 3: Tool Integration

```ruby
# Define a custom tool
class DatabaseSearchTool < RubyLLM::Tool
  description "Search for records in the application database"

  param :model_name, desc: "The ActiveRecord model to search"
  param :query, desc: "Search query string"
  param :limit, desc: "Maximum number of results", required: false

  def execute(model_name:, query:, limit: 10)
    # Validate model exists and is allowed
    allowed_models = %w[User Post Comment]
    unless model_name.in?(allowed_models)
      return { error: "Model #{model_name} is not searchable" }
    end

    begin
      model_class = model_name.constantize
      results = model_class.where("name ILIKE ?", "%#{query}%")
                          .limit(limit.to_i)
                          .pluck(:id, :name, :created_at)

      {
        model: model_name,
        query: query,
        count: results.size,
        results: results.map do |id, name, created_at|
          { id: id, name: name, created_at: created_at }
        end
      }
    rescue => e
      Rails.logger.error "DatabaseSearchTool error: #{e.message}"
      { error: "Search failed: #{e.message}" }
    end
  end
end

# Use tool in a chat
chat.with_tools([DatabaseSearchTool])
    .ask("Find all users named John")
```

### Step 4: ActiveRecord Callbacks and Hooks

```ruby
class Chat < ApplicationRecord
  acts_as_chat

  # Lifecycle callbacks
  before_create :set_default_title
  after_create :setup_initial_context
  before_destroy :cleanup_associated_data

  # RubyLLM-specific callbacks
  before_ai_response :log_request
  after_ai_response :update_statistics
  on_streaming_chunk :broadcast_chunk

  private

  def set_default_title
    self.title ||= "Chat #{Time.current.strftime('%Y-%m-%d %H:%M')}"
  end

  def setup_initial_context
    # Add system message with context
    messages.create!(
      role: 'system',
      content: "You are a helpful assistant for #{user&.name || 'the user'}."
    )
  end

  def cleanup_associated_data
    # Clean up any external resources
    messages.includes(:files_attachments).find_each do |message|
      message.files.purge
    end
  end

  def log_request
    Rails.logger.info "AI request initiated for chat #{id}"
  end

  def update_statistics
    increment!(:response_count)
    touch(:last_activity_at)
  end

  def broadcast_chunk(chunk)
    ActionCable.server.broadcast(
      "chat_#{id}",
      {
        type: 'chunk',
        content: chunk.content,
        finished: chunk.finished?
      }
    )
  end
end
```

### Step 5: ActionCable Integration for Real-time Features

```ruby
# app/channels/chat_channel.rb
class ChatChannel < ApplicationCable::Channel
  def subscribed
    chat = Chat.find(params[:chat_id])
    stream_for chat
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def send_message(data)
    chat = Chat.find(params[:chat_id])
    message = chat.messages.build(
      content: data['content'],
      role: 'user'
    )

    if message.save
      # Broadcast user message immediately
      ChatChannel.broadcast_to(chat, {
        type: 'new_message',
        message: ApplicationController.render(
          partial: 'messages/message',
          locals: { message: message }
        )
      })

      # Process AI response in background
      AiResponseJob.perform_later(chat)
    end
  end
end

# Background job for AI responses
class AiResponseJob < ApplicationJob
  queue_as :ai_responses

  def perform(chat)
    chat.ask(chat.messages.last.content) do |chunk|
      # Broadcast each chunk in real-time
      ChatChannel.broadcast_to(chat, {
        type: 'streaming_chunk',
        content: chunk.content,
        finished: chunk.finished?
      })
    end
  rescue => e
    # Broadcast error to user
    ChatChannel.broadcast_to(chat, {
      type: 'error',
      message: "Sorry, I encountered an error: #{e.message}"
    })
  end
end
```

### Step 6: Model Registry (v1.7.0+)

```ruby
# Access model information
models = RubyLLM::Model.all
gpt4_model = RubyLLM::Model.find_by(name: 'gpt-4')

# Query models by capabilities
vision_models = RubyLLM::Model.with_capability(:vision)
tool_models = RubyLLM::Model.with_capability(:tools)

# Custom model configuration
class CustomModelConfig
  def self.setup_models
    # Register custom model configurations
    RubyLLM::Model.create_or_update(
      name: 'custom-gpt-4',
      provider: 'openai',
      capabilities: ['chat', 'tools', 'vision'],
      context_window: 128000,
      max_tokens: 4096
    )
  end
end
```

## API Reference

### acts_as_chat Methods

```ruby
# Core conversation methods
chat.ask(prompt, &block)                    # Send message and get response
chat.say(message)                           # Add message without AI response
chat.with_model(model_name)                 # Set AI model
chat.with_temperature(temp)                 # Set creativity level (0.0-2.0)
chat.with_instructions(instructions)        # Set system instructions
chat.with_tools(tool_array)                 # Add function calling tools
chat.with_context(context_hash)             # Add custom context

# Streaming methods
chat.stream(prompt) { |chunk| ... }         # Stream response chunks
chat.on_chunk { |chunk| ... }               # Set chunk callback
chat.on_complete { |response| ... }         # Set completion callback
chat.on_error { |error| ... }               # Set error callback

# Context management
chat.context                                # Get current context
chat.context_tokens                         # Get token count
chat.clear_context                          # Reset conversation
chat.trim_context(max_tokens)               # Trim to token limit

# Message access
chat.messages                               # ActiveRecord association
chat.user_messages                          # Filter user messages
chat.assistant_messages                     # Filter AI messages
chat.system_messages                        # Filter system messages
```

### acts_as_message Methods

```ruby
# Content methods
message.content                             # Get message text
message.content=(text)                      # Set message text
message.append_content(text)                # Append to existing content
message.role                                # Get message role
message.role=(role)                         # Set role ('user', 'assistant', etc.)

# Attachment methods
message.files                               # ActiveStorage association
message.files.attach(files)                 # Attach files
message.has_attachments?                    # Check for attachments
message.attachment_count                    # Count attachments
message.attachment_types                    # Get MIME types of attachments

# Metadata methods
message.metadata                            # Get custom metadata hash
message.metadata=(hash)                     # Set metadata
message.add_metadata(key, value)            # Add metadata entry
message.tokens                              # Get token usage info
message.model                               # Get AI model used

# Processing methods
message.process!                            # Trigger processing
message.processed?                          # Check if processed
message.processing_error                    # Get processing error if any
```

### acts_as_tool_call Methods

```ruby
# Execution methods
tool_call.execute!                          # Execute the tool
tool_call.executed?                         # Check execution status
tool_call.result                            # Get execution result
tool_call.error                             # Get execution error

# Tool information
tool_call.name                              # Tool name
tool_call.arguments                         # Tool arguments hash
tool_call.tool_class                        # Get tool class
tool_call.duration                          # Execution duration

# State management
tool_call.pending?                          # Not yet executed
tool_call.executing?                        # Currently executing
tool_call.completed?                        # Successfully completed
tool_call.failed?                           # Execution failed
```

## Code Examples

### Basic Chat Implementation

```ruby
# Controller
class ChatsController < ApplicationController
  before_action :authenticate_user!

  def show
    @chat = current_user.chats.find(params[:id])
    @message = @chat.messages.build
  end

  def create
    @chat = current_user.chats.build(chat_params)

    if @chat.save
      redirect_to @chat
    else
      render :new
    end
  end

  private

  def chat_params
    params.require(:chat).permit(:title, :instructions)
  end
end

# Message creation with AI response
class MessagesController < ApplicationController
  def create
    @chat = Chat.find(params[:chat_id])
    @message = @chat.messages.build(message_params)

    if @message.save
      # Stream AI response
      AiStreamingJob.perform_later(@chat, @message)
      head :ok
    else
      render json: { errors: @message.errors }, status: :unprocessable_entity
    end
  end

  private

  def message_params
    params.require(:message).permit(:content, files: [])
  end
end
```

### Advanced Streaming Implementation

```ruby
class AiStreamingJob < ApplicationJob
  include ActionCable::Server::Broadcasting

  def perform(chat, user_message)
    response_message = chat.messages.create!(
      role: 'assistant',
      content: ''
    )

    chat.ask(user_message.content) do |chunk|
      # Update message content
      response_message.content += chunk.content
      response_message.save!

      # Broadcast chunk via ActionCable
      ActionCable.server.broadcast(
        "chat_#{chat.id}",
        {
          type: 'chunk',
          message_id: response_message.id,
          content: chunk.content,
          finished: chunk.finished?
        }
      )

      # Also broadcast via Turbo Stream
      broadcast_update_to(
        chat,
        target: "message_#{response_message.id}",
        partial: 'messages/message_content',
        locals: { message: response_message }
      )
    end
  rescue => e
    Rails.logger.error "AI streaming error: #{e.message}"

    # Broadcast error
    ActionCable.server.broadcast(
      "chat_#{chat.id}",
      {
        type: 'error',
        message: 'Sorry, I encountered an error processing your message.'
      }
    )
  end
end
```

### Multi-modal Message Handling

```ruby
class MultiModalMessagesController < ApplicationController
  def create_with_files
    @chat = Chat.find(params[:chat_id])

    ActiveRecord::Base.transaction do
      # Create message with text content
      @message = @chat.messages.create!(
        content: params[:content],
        role: 'user'
      )

      # Attach files if present
      if params[:files].present?
        @message.files.attach(params[:files])

        # Process each file type
        @message.files.each do |file|
          case file.content_type
          when /\Aimage/
            process_image_file(file)
          when /\Aaudio/
            process_audio_file(file)
          when /\Avideo/
            process_video_file(file)
          when 'application/pdf'
            process_pdf_file(file)
          when /\Atext/
            process_text_file(file)
          end
        end
      end

      # Generate AI response considering all attachments
      AiResponseWithAttachmentsJob.perform_later(@message)
    end

    render json: { message_id: @message.id }
  end

  private

  def process_image_file(file)
    # Validate image dimensions, file size
    # Generate thumbnails if needed
    # Extract metadata
  end

  def process_audio_file(file)
    # Validate audio format
    # Extract duration, format info
    # Potentially transcribe with Whisper
  end

  def process_video_file(file)
    # Validate video format
    # Extract metadata (duration, resolution)
    # Generate thumbnail frame
  end

  def process_pdf_file(file)
    # Extract text content
    # Validate page count
    # Generate page thumbnails
  end

  def process_text_file(file)
    # Validate encoding
    # Check file size limits
    # Extract and validate content
  end
end
```

### Custom Tool with Rails Integration

```ruby
class UserManagementTool < RubyLLM::Tool
  description "Manage user accounts and retrieve user information"

  param :action, desc: "Action to perform: 'search', 'create', 'update', 'deactivate'"
  param :user_id, desc: "User ID for update/deactivate actions", required: false
  param :email, desc: "Email for search/create actions", required: false
  param :name, desc: "Name for create/update actions", required: false
  param :role, desc: "Role for create/update actions", required: false

  def execute(action:, user_id: nil, email: nil, name: nil, role: nil)
    case action
    when 'search'
      search_users(email)
    when 'create'
      create_user(email, name, role)
    when 'update'
      update_user(user_id, name, role)
    when 'deactivate'
      deactivate_user(user_id)
    else
      { error: "Unknown action: #{action}" }
    end
  rescue => e
    Rails.logger.error "UserManagementTool error: #{e.message}"
    { error: "Operation failed: #{e.message}" }
  end

  private

  def search_users(email)
    users = if email.present?
              User.where("email ILIKE ?", "%#{email}%")
            else
              User.all
            end.limit(10)

    {
      action: 'search',
      count: users.count,
      users: users.map do |user|
        {
          id: user.id,
          email: user.email,
          name: user.name,
          role: user.role,
          active: user.active?,
          created_at: user.created_at
        }
      end
    }
  end

  def create_user(email, name, role)
    return { error: "Email is required" } unless email.present?

    user = User.create!(
      email: email,
      name: name || email.split('@').first,
      role: role || 'user',
      password: SecureRandom.hex(16)
    )

    # Send welcome email
    UserMailer.welcome_email(user).deliver_later

    {
      action: 'create',
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        role: user.role
      },
      message: "User created successfully"
    }
  end

  def update_user(user_id, name, role)
    return { error: "User ID is required" } unless user_id.present?

    user = User.find(user_id)
    update_params = {}
    update_params[:name] = name if name.present?
    update_params[:role] = role if role.present?

    user.update!(update_params)

    {
      action: 'update',
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        role: user.role
      },
      message: "User updated successfully"
    }
  end

  def deactivate_user(user_id)
    return { error: "User ID is required" } unless user_id.present?

    user = User.find(user_id)
    user.update!(active: false)

    {
      action: 'deactivate',
      user_id: user.id,
      message: "User deactivated successfully"
    }
  end
end
```

## Important Considerations

### Version Compatibility
- **Rails 7.0+**: Full feature support including Turbo Streams
- **Rails 6.1+**: Core features supported, limited streaming capabilities
- **ActiveStorage 6.0+**: Required for file attachment handling
- **RubyLLM 1.7.0+**: Required for `use_new_acts_as` and model registry features

### Security Considerations
```ruby
# Secure file upload validation
class Message < ApplicationRecord
  validate :secure_file_validation

  private

  def secure_file_validation
    return unless files.attached?

    files.each do |file|
      # Check file size
      if file.byte_size > 50.megabytes
        errors.add(:files, "File too large: #{file.filename}")
      end

      # Validate MIME type
      unless allowed_content_types.include?(file.content_type)
        errors.add(:files, "Unsupported file type: #{file.filename}")
      end

      # Scan for malware (if using a service like ClamAV)
      if malware_detected?(file)
        errors.add(:files, "Security threat detected: #{file.filename}")
      end
    end
  end

  def allowed_content_types
    %w[
      image/jpeg image/png image/gif image/webp
      audio/mpeg audio/wav audio/mp3 audio/m4a
      video/mp4 video/webm video/mov
      application/pdf
      text/plain text/markdown text/csv
    ]
  end

  def malware_detected?(file)
    # Implement malware scanning logic
    # Return true if malware detected
    false
  end
end

# Secure tool implementation
class SecureUserTool < RubyLLM::Tool
  description "Securely manage user data"

  param :action, desc: "Allowed actions: search, view"
  param :user_id, desc: "User ID to look up", required: false

  def execute(action:, user_id: nil)
    # Validate permissions based on current context
    unless authorized_action?(action)
      return { error: "Unauthorized action: #{action}" }
    end

    # Sanitize inputs
    user_id = user_id.to_i if user_id.present?

    case action
    when 'search'
      # Only return safe, public information
      search_public_users
    when 'view'
      view_user_safely(user_id)
    else
      { error: "Invalid action: #{action}" }
    end
  end

  private

  def authorized_action?(action)
    # Implement authorization logic
    %w[search view].include?(action)
  end

  def search_public_users
    # Return only safe, public information
    User.active.limit(10).pluck(:id, :public_name, :created_at)
  end

  def view_user_safely(user_id)
    user = User.find_by(id: user_id)
    return { error: "User not found" } unless user

    # Return only safe information
    {
      id: user.id,
      public_name: user.public_name,
      member_since: user.created_at.year,
      active: user.active?
    }
  end
end
```

### Performance Considerations
- **Database Indexing**: Add indexes on frequently queried columns
- **Message Pagination**: Implement pagination for large conversations
- **File Storage**: Use cloud storage (S3, etc.) for production file handling
- **Caching**: Cache frequently accessed model metadata and responses
- **Background Processing**: Always use background jobs for AI operations

### Common Pitfalls
- **Empty Message Cleanup**: RubyLLM automatically handles this, but be aware of the behavior
- **Token Limits**: Monitor conversation length and implement context trimming
- **File Size Limits**: Implement proper file size validation and user feedback
- **Error Handling**: Always wrap AI operations in error handling blocks
- **Memory Usage**: Large file attachments can consume significant memory during processing

## Best Practices for Rails Applications

### 1. Separation of Concerns
```ruby
# Good: Separate AI logic into service objects
class ChatService
  def initialize(chat)
    @chat = chat
  end

  def send_message(content, files: [])
    ActiveRecord::Base.transaction do
      message = create_user_message(content, files)
      process_ai_response(message)
      message
    end
  end

  private

  def create_user_message(content, files)
    message = @chat.messages.create!(content: content, role: 'user')
    message.files.attach(files) if files.any?
    message
  end

  def process_ai_response(user_message)
    AiResponseJob.perform_later(@chat, user_message)
  end
end

# Usage in controller
class MessagesController < ApplicationController
  def create
    @chat = Chat.find(params[:chat_id])
    service = ChatService.new(@chat)

    @message = service.send_message(
      params[:content],
      files: params[:files]
    )

    render json: { message_id: @message.id }
  end
end
```

### 2. Background Processing
```ruby
# Always use background jobs for AI operations
class AiResponseJob < ApplicationJob
  queue_as :ai_responses
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(chat, user_message)
    chat.with_model(select_best_model(user_message))
        .ask(user_message.content) do |chunk|
      broadcast_chunk(chat, chunk)
    end
  rescue => e
    handle_ai_error(chat, e)
  end

  private

  def select_best_model(message)
    if message.files.any?(&:image?)
      'gpt-4-vision-preview'
    elsif message.files.any?(&:audio?)
      'gpt-4'  # Model capable of handling audio descriptions
    else
      'gpt-3.5-turbo'
    end
  end

  def handle_ai_error(chat, error)
    Rails.logger.error "AI error for chat #{chat.id}: #{error.message}"

    # Create error message for user
    chat.messages.create!(
      role: 'assistant',
      content: "I'm sorry, I encountered an error processing your message. Please try again.",
      metadata: { error: error.class.name }
    )
  end
end
```

### 3. Monitoring and Observability
```ruby
# Add instrumentation for AI operations
class InstrumentedChat < Chat
  acts_as_chat

  around_ai_request :instrument_request

  private

  def instrument_request
    start_time = Time.current
    tokens_before = total_tokens

    yield

    duration = Time.current - start_time
    tokens_used = total_tokens - tokens_before

    Rails.logger.info(
      "AI Request Completed",
      chat_id: id,
      duration: duration,
      tokens_used: tokens_used,
      model: current_model
    )

    # Send metrics to monitoring service
    Metrics.record('ai.request.duration', duration, tags: {
      model: current_model,
      chat_id: id
    })

    Metrics.record('ai.tokens.used', tokens_used, tags: {
      model: current_model,
      type: 'completion'
    })
  end
end
```

### 4. Testing Strategies
```ruby
# Test with VCR for consistent AI responses
RSpec.describe ChatService do
  let(:chat) { create(:chat) }
  let(:service) { ChatService.new(chat) }

  describe '#send_message' do
    it 'creates user message and triggers AI response', :vcr do
      message = service.send_message("Hello, AI!")

      expect(message.content).to eq("Hello, AI!")
      expect(message.role).to eq('user')
      expect(AiResponseJob).to have_been_enqueued.with(chat, message)
    end

    it 'handles file attachments' do
      file = fixture_file_upload('test_image.jpg', 'image/jpeg')

      message = service.send_message("Describe this image", files: [file])

      expect(message.files).to be_attached
      expect(message.files.first.content_type).to eq('image/jpeg')
    end
  end
end

# Mock AI responses for faster tests
RSpec.describe Chat do
  let(:chat) { create(:chat) }

  before do
    allow(RubyLLM).to receive(:chat).and_return(
      double(ask: double(content: "Mocked AI response"))
    )
  end

  it 'generates appropriate responses' do
    response = chat.ask("Test question")
    expect(response.content).to eq("Mocked AI response")
  end
end
```

This comprehensive Rails integration guide provides everything needed to successfully implement RubyLLM in a Rails application, with particular emphasis on attachment handling, real-time features, and production-ready patterns.