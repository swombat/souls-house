# RubyLLM Tools - Chat Integration

## Overview

RubyLLM tools integrate seamlessly with Rails chat systems through the `acts_as_message` functionality. This allows tools to participate in persisted conversations, with automatic tracking of tool calls and results in your database.

## acts_as_tool Integration

The `acts_as_message` integration automatically handles tool persistence and conversation continuity:

```ruby
# app/models/chat.rb
class Chat < ApplicationRecord
  acts_as_message
  belongs_to :user

  # Tool calls and results are automatically persisted
  # as messages in the conversation
end

# Usage in controllers
class ChatsController < ApplicationController
  def create
    @chat = current_user.chats.create!(model: 'gpt-4')

    # Register tools with the chat
    @chat.with_tool(Weather)
    @chat.with_tool(UserProfile)
    @chat.with_tool(DatabaseQuery)

    redirect_to @chat
  end

  def ask
    @chat = current_user.chats.find(params[:id])

    response = @chat.ask(params[:message])

    # Tool calls are automatically persisted in the database
    # Both the tool call and tool result are saved as messages

    render json: { response: response }
  end
end
```

## Tool Call Persistence

When a tool is used in a chat context, the following are automatically saved:

1. **User Message** - The original user query
2. **Assistant Message** - The AI's response that includes tool calls
3. **Tool Call Messages** - Each tool invocation and its parameters
4. **Tool Result Messages** - The output from each tool execution

```ruby
# Example conversation flow
chat = Chat.create!(model: 'gpt-4')
chat.with_tool(Weather)

# User asks: "What's the weather in London?"
response = chat.ask("What's the weather in London?")

# Database now contains:
# 1. Message(role: 'user', content: "What's the weather in London?")
# 2. Message(role: 'assistant', content: "I'll check the weather for you", tool_calls: [...])
# 3. Message(role: 'tool', tool_call_id: "xyz", content: weather_result)
# 4. Message(role: 'assistant', content: "The weather in London is sunny and 22°C")

# Access conversation history
chat.messages.each do |message|
  puts "#{message.role}: #{message.content}"
  if message.tool_calls.present?
    puts "  Tool calls: #{message.tool_calls}"
  end
end
```

## Tool Registration Patterns

### Single Tool Registration

```ruby
class SupportChatController < ApplicationController
  def create
    @chat = current_user.support_chats.create!(model: 'gpt-4')

    # Register a single customer service tool
    @chat.with_tool(CustomerServiceTool)

    render json: { chat_id: @chat.id }
  end
end

class CustomerServiceTool < RubyLLM::Tool
  description "Handles customer service queries and ticket creation"

  param :query_type, desc: "Type of query: billing, technical, general"
  param :urgency, desc: "Urgency level: low, medium, high"
  param :details, desc: "Detailed description of the issue"

  def execute(query_type:, urgency:, details:)
    # Create support ticket
    ticket = SupportTicket.create!(
      query_type: query_type,
      urgency: urgency,
      description: details,
      status: 'open'
    )

    {
      ticket_id: ticket.id,
      message: "Support ticket #{ticket.id} created. We'll respond within #{response_time(urgency)}.",
      estimated_response: response_time(urgency)
    }
  end

  private

  def response_time(urgency)
    case urgency
    when 'high' then '2 hours'
    when 'medium' then '24 hours'
    else '48 hours'
    end
  end
end
```

### Multiple Tool Registration

```ruby
class AdminChatController < ApplicationController
  before_action :ensure_admin

  def create
    @chat = current_user.admin_chats.create!(model: 'gpt-4')

    # Register multiple admin tools
    @chat.with_tool(UserManagement)
    @chat.with_tool(SystemMetrics)
    @chat.with_tool(DatabaseQuery)
    @chat.with_tool(LogAnalyzer)
    @chat.with_tool(BackupManager)

    render json: { chat_id: @chat.id }
  end
end
```

### Conditional Tool Registration

```ruby
class DynamicChatController < ApplicationController
  def create
    @chat = current_user.chats.create!(model: 'gpt-4')

    # Register tools based on user permissions
    register_tools_for_user(@chat, current_user)

    render json: { chat_id: @chat.id }
  end

  private

  def register_tools_for_user(chat, user)
    # Basic tools for all users
    chat.with_tool(Weather)
    chat.with_tool(Calculator)

    # Role-based tool access
    if user.admin?
      chat.with_tool(UserManagement)
      chat.with_tool(SystemMetrics)
      chat.with_tool(DatabaseQuery)
    end

    if user.analyst?
      chat.with_tool(ReportGenerator)
      chat.with_tool(DataExporter)
    end

    if user.customer_service?
      chat.with_tool(CustomerServiceTool)
      chat.with_tool(TicketManager)
    end

    # Feature-based access
    if user.has_feature?(:file_processing)
      chat.with_tool(FileProcessor)
    end
  end
end
```

## Tool Context and State

Tools can access chat context and maintain state across conversations:

```ruby
class ContextAwareTool < RubyLLM::Tool
  description "Demonstrates context-aware tool behavior"

  param :action, desc: "Action to perform"

  def execute(action:, chat_context: nil)
    # Access previous messages in the conversation
    if chat_context && chat_context.respond_to?(:messages)
      previous_messages = chat_context.messages.recent.limit(5)

      # Analyze conversation history
      user_preferences = analyze_user_preferences(previous_messages)

      case action
      when "summarize"
        summarize_conversation(previous_messages)
      when "recommend"
        make_recommendations(user_preferences)
      when "continue"
        continue_previous_topic(previous_messages)
      end
    else
      { message: "No conversation context available" }
    end
  end

  private

  def analyze_user_preferences(messages)
    # Analyze user's previous messages for preferences
    user_messages = messages.where(role: 'user')

    {
      topics: extract_topics(user_messages),
      sentiment: analyze_sentiment(user_messages),
      complexity_preference: determine_complexity_level(user_messages)
    }
  end
end
```

## Streaming Tool Responses

Tools can work with streaming responses for real-time feedback:

```ruby
class StreamingReportTool < RubyLLM::Tool
  description "Generates reports with streaming updates"

  param :report_type, desc: "Type of report to generate"

  def execute(report_type:)
    # For streaming, tools can yield intermediate results
    # This depends on your streaming implementation

    yield_progress("Starting #{report_type} report generation...")

    data = fetch_report_data(report_type)
    yield_progress("Data fetched. Processing #{data.count} records...")

    processed_data = process_data(data)
    yield_progress("Data processed. Generating visualizations...")

    chart_path = create_charts(processed_data)
    yield_progress("Charts created. Finalizing report...")

    report_path = generate_final_report(processed_data, chart_path)

    RubyLLM::Content.new(
      "#{report_type} report completed successfully",
      [report_path, chart_path]
    )
  end

  private

  def yield_progress(message)
    # Implementation depends on your streaming setup
    # This might broadcast to ActionCable or similar
    Rails.logger.info("Tool Progress: #{message}")
  end
end
```

## Error Handling in Chat Context

Handle errors gracefully in persistent chat conversations:

```ruby
class RobustChatTool < RubyLLM::Tool
  description "Demonstrates robust error handling in chat context"

  param :operation, desc: "Operation to perform"

  def execute(operation:)
    case operation
    when "risky_operation"
      perform_risky_operation
    when "network_call"
      make_network_request
    when "database_query"
      execute_database_query
    end
  rescue ActiveRecord::RecordNotFound => e
    log_tool_error(e, "Database record not found")
    {
      error: "The requested data could not be found.",
      suggestion: "Please check the ID and try again."
    }
  rescue Net::TimeoutError => e
    log_tool_error(e, "Network timeout")
    {
      error: "The external service is currently unavailable.",
      suggestion: "Please try again in a few minutes."
    }
  rescue StandardError => e
    log_tool_error(e, "Unexpected error")
    {
      error: "An unexpected error occurred.",
      suggestion: "Please try a different approach or contact support."
    }
  end

  private

  def log_tool_error(exception, context)
    Rails.logger.error("Tool Error [#{context}]: #{exception.message}")
    Rails.logger.error(exception.backtrace.join("\n"))

    # Optionally report to error tracking service
    # Bugsnag.notify(exception, context: context)
  end
end
```

## Tool Result Formatting

Format tool results appropriately for chat display:

```ruby
class UserFriendlyTool < RubyLLM::Tool
  description "Demonstrates user-friendly tool responses"

  param :user_id, desc: "User ID to look up"

  def execute(user_id:)
    user = User.find_by(id: user_id)

    return format_error("User not found") unless user

    # Format response for chat display
    format_user_info(user)
  end

  private

  def format_user_info(user)
    {
      user_summary: "#{user.name} (#{user.email})",
      account_status: user.active? ? "Active" : "Inactive",
      member_since: user.created_at.strftime("%B %Y"),
      last_activity: format_last_activity(user.last_sign_in_at),
      quick_stats: {
        posts: user.posts.count,
        comments: user.comments.count,
        likes_received: user.posts.sum(:likes_count)
      },
      display_message: build_display_message(user)
    }
  end

  def format_last_activity(timestamp)
    return "Never" unless timestamp

    if timestamp > 1.week.ago
      "#{time_ago_in_words(timestamp)} ago"
    else
      timestamp.strftime("%B %d, %Y")
    end
  end

  def build_display_message(user)
    "Found user #{user.name}. They've been a member since #{user.created_at.strftime('%B %Y')} and have posted #{user.posts.count} times."
  end

  def format_error(message)
    {
      error: true,
      message: message,
      display_message: "I couldn't find that user. Please check the user ID and try again."
    }
  end
end
```

## Testing Tool Integration

Test tools within chat contexts:

```ruby
# test/integration/chat_tools_test.rb
class ChatToolsTest < ActionDispatch::IntegrationTest
  def setup
    @user = users(:admin)
    @chat = @user.chats.create!(model: 'gpt-4')
    @chat.with_tool(UserManagement)
  end

  test "tool calls are persisted in chat messages" do
    response = @chat.ask("Show me user details for ID 123")

    # Verify tool call was made and persisted
    tool_messages = @chat.messages.where(role: 'tool')
    assert tool_messages.any?

    # Verify response contains expected data
    assert_includes response, "user details"
  end

  test "tool errors are handled gracefully in chat" do
    response = @chat.ask("Show me user details for ID 99999")

    # Should get friendly error message, not exception
    assert_includes response.downcase, "not found"

    # Conversation should continue normally
    follow_up = @chat.ask("What about user ID 1?")
    assert_not_includes follow_up.downcase, "error"
  end
end
```

## Performance Considerations

Optimize tool performance in chat contexts:

```ruby
class OptimizedChatTool < RubyLLM::Tool
  description "Demonstrates performance optimization"

  def execute(**params)
    # Use caching for expensive operations
    Rails.cache.fetch("tool_result_#{cache_key(params)}", expires_in: 5.minutes) do
      perform_expensive_operation(params)
    end
  end

  private

  def cache_key(params)
    Digest::MD5.hexdigest(params.to_json)
  end

  def perform_expensive_operation(params)
    # Expensive computation here
    sleep(2) # Simulated expensive operation
    { result: "Computed result for #{params}" }
  end
end
```

## Next Steps

- Learn about [Tool Execution Flow](tools-execution-flow.md) - advanced patterns and error handling
- Explore [Callbacks](tools-callbacks.md) - monitoring and responding to tool events in chat
- Understand [Halting](tools-halting.md) - controlling tool execution flow