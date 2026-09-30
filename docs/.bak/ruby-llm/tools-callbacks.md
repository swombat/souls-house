# RubyLLM Tools - Callback System

## Overview

RubyLLM provides a comprehensive callback system for monitoring and responding to tool events throughout the conversation lifecycle. Callbacks enable debugging, auditing, usage tracking, and execution control in your Rails applications.

## Core Callback Events

RubyLLM offers four primary event handlers that cover the complete chat lifecycle:

### 1. on_tool_call - Tool Invocation Monitoring

Called when the AI decides to use a tool, before the tool executes:

```ruby
chat = RubyLLM.chat(model: 'gpt-4')
         .with_tool(Weather)
         .on_tool_call do |tool_call|
           Rails.logger.info("Tool called: #{tool_call.name}")
           Rails.logger.info("Arguments: #{tool_call.arguments}")
           Rails.logger.info("Call ID: #{tool_call.id}")
         end

response = chat.ask("What's the weather in London?")
```

### 2. on_tool_result - Tool Result Monitoring

Called after a tool completes execution and returns its result:

```ruby
chat = RubyLLM.chat(model: 'gpt-4')
         .with_tool(DatabaseQuery)
         .on_tool_result do |result|
           Rails.logger.info("Tool completed with result: #{result}")

           # Log result size for monitoring
           if result.is_a?(Hash) && result[:records]
             Rails.logger.info("Returned #{result[:records].length} records")
           end
         end
```

### 3. on_new_message - Message Start Monitoring

Called when the AI starts sending a response (before tool calls):

```ruby
chat = RubyLLM.chat(model: 'gpt-4')
         .on_new_message do |message|
           Rails.logger.info("AI response started: #{message.content[0..100]}...")
         end
```

### 4. on_end_message - Message Completion Monitoring

Called after the complete assistant message (including all tool calls/results) is received:

```ruby
chat = RubyLLM.chat(model: 'gpt-4')
         .on_end_message do |message|
           Rails.logger.info("AI response completed")
           Rails.logger.info("Total tool calls: #{message.tool_calls&.length || 0}")
         end
```

## Comprehensive Callback Example

Combine multiple callbacks for complete monitoring:

```ruby
class MonitoredChatService
  def initialize(user)
    @user = user
    @tool_call_count = 0
    @start_time = Time.current
  end

  def create_chat
    RubyLLM.chat(model: 'gpt-4')
      .with_tool(Weather)
      .with_tool(DatabaseQuery)
      .with_tool(ReportGenerator)
      .on_new_message(&method(:handle_new_message))
      .on_tool_call(&method(:handle_tool_call))
      .on_tool_result(&method(:handle_tool_result))
      .on_end_message(&method(:handle_end_message))
  end

  private

  def handle_new_message(message)
    Rails.logger.info("User #{@user.id}: AI response started")

    # Track response start time
    @response_start = Time.current
  end

  def handle_tool_call(tool_call)
    @tool_call_count += 1

    Rails.logger.info("User #{@user.id}: Tool call ##{@tool_call_count}")
    Rails.logger.info("  Tool: #{tool_call.name}")
    Rails.logger.info("  Arguments: #{tool_call.arguments}")

    # Create audit log
    ToolUsageLog.create!(
      user: @user,
      tool_name: tool_call.name,
      arguments: tool_call.arguments,
      call_id: tool_call.id,
      called_at: Time.current
    )

    # Check usage limits
    check_tool_usage_limits(tool_call)
  end

  def handle_tool_result(result)
    Rails.logger.info("User #{@user.id}: Tool result received")

    # Log result metrics
    if result.is_a?(Hash)
      Rails.logger.info("  Result keys: #{result.keys}")
      Rails.logger.info("  Error: #{result[:error]}" if result[:error]
    end

    # Update audit log with result
    if @current_tool_log
      @current_tool_log.update!(
        result: result,
        completed_at: Time.current,
        success: !result.is_a?(Hash) || !result[:error]
      )
    end
  end

  def handle_end_message(message)
    total_time = Time.current - @start_time
    response_time = Time.current - @response_start

    Rails.logger.info("User #{@user.id}: Conversation completed")
    Rails.logger.info("  Total time: #{total_time.round(2)}s")
    Rails.logger.info("  Response time: #{response_time.round(2)}s")
    Rails.logger.info("  Tool calls: #{@tool_call_count}")

    # Create conversation summary
    ConversationMetrics.create!(
      user: @user,
      total_duration: total_time,
      response_duration: response_time,
      tool_calls_count: @tool_call_count,
      message_length: message.content.length
    )
  end

  def check_tool_usage_limits(tool_call)
    # Implement usage limits based on user tier
    daily_limit = @user.premium? ? 1000 : 100
    daily_usage = ToolUsageLog.where(
      user: @user,
      called_at: 1.day.ago..Time.current
    ).count

    if daily_usage >= daily_limit
      Rails.logger.warn("User #{@user.id} exceeded daily tool limit")
      # Note: Don't raise exception here as it breaks conversation flow
      # Instead, notify user through different means
      NotificationService.send_usage_limit_warning(@user)
    end
  end
end
```

## Rails Integration Patterns

### Database Logging

Create models to track tool usage:

```ruby
# Migration
class CreateToolUsageLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :tool_usage_logs do |t|
      t.references :user, null: false, foreign_key: true
      t.string :tool_name, null: false
      t.json :arguments
      t.json :result
      t.string :call_id
      t.timestamp :called_at
      t.timestamp :completed_at
      t.boolean :success
      t.decimal :duration, precision: 8, scale: 3

      t.timestamps
    end

    add_index :tool_usage_logs, [:user_id, :called_at]
    add_index :tool_usage_logs, :tool_name
  end
end

# Model
class ToolUsageLog < ApplicationRecord
  belongs_to :user

  scope :successful, -> { where(success: true) }
  scope :failed, -> { where(success: false) }
  scope :for_tool, ->(tool_name) { where(tool_name: tool_name) }
  scope :recent, -> { where(called_at: 1.week.ago..Time.current) }

  def duration_seconds
    return nil unless called_at && completed_at
    completed_at - called_at
  end
end
```

### Real-time Monitoring with ActionCable

Stream tool events to browser in real-time:

```ruby
class ToolMonitoringChannel < ApplicationCable::Channel
  def subscribed
    stream_from "tool_monitoring_#{current_user.id}"
  end
end

# In your callback
def handle_tool_call(tool_call)
  # Broadcast to user's browser
  ActionCable.server.broadcast(
    "tool_monitoring_#{@user.id}",
    {
      type: 'tool_call',
      tool_name: tool_call.name,
      arguments: tool_call.arguments,
      timestamp: Time.current.iso8601
    }
  )
end

def handle_tool_result(result)
  ActionCable.server.broadcast(
    "tool_monitoring_#{@user.id}",
    {
      type: 'tool_result',
      result: result,
      timestamp: Time.current.iso8601
    }
  )
end
```

## Error Handling in Callbacks

Handle callback errors gracefully to avoid breaking conversations:

```ruby
class SafeCallbackHandler
  def self.safe_callback(name, &block)
    proc do |*args|
      begin
        block.call(*args)
      rescue => e
        Rails.logger.error("Callback #{name} failed: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))

        # Report to error tracking but don't re-raise
        # Bugsnag.notify(e, context: { callback: name })
      end
    end
  end
end

# Usage
chat = RubyLLM.chat(model: 'gpt-4')
         .with_tool(Weather)
         .on_tool_call(SafeCallbackHandler.safe_callback('tool_call') do |tool_call|
           # Your callback logic here
           complex_logging_operation(tool_call)
         end)
```

## Usage Limiting and Control

Implement sophisticated usage controls:

```ruby
class ToolUsageController
  def initialize(user)
    @user = user
    @call_counts = Hash.new(0)
    @session_start = Time.current
  end

  def tool_call_callback
    proc do |tool_call|
      @call_counts[tool_call.name] += 1

      # Check per-tool limits
      check_tool_specific_limits(tool_call)

      # Check session limits
      check_session_limits

      # Log for analytics
      log_tool_usage(tool_call)
    end
  end

  private

  def check_tool_specific_limits(tool_call)
    tool_limits = {
      'DatabaseQuery' => @user.premium? ? 50 : 10,
      'FileProcessor' => @user.premium? ? 20 : 5,
      'ReportGenerator' => @user.premium? ? 10 : 2
    }

    limit = tool_limits[tool_call.name] || 100

    if @call_counts[tool_call.name] > limit
      Rails.logger.warn("Tool #{tool_call.name} limit exceeded for user #{@user.id}")

      # Send warning through separate channel
      NotificationService.send_tool_limit_warning(@user, tool_call.name)
    end
  end

  def check_session_limits
    session_duration = Time.current - @session_start
    total_calls = @call_counts.values.sum

    max_session_calls = @user.premium? ? 200 : 50
    max_session_duration = @user.premium? ? 1.hour : 15.minutes

    if total_calls > max_session_calls
      Rails.logger.warn("Session call limit exceeded for user #{@user.id}")
    end

    if session_duration > max_session_duration
      Rails.logger.warn("Session duration limit exceeded for user #{@user.id}")
    end
  end

  def log_tool_usage(tool_call)
    ToolAnalytics.increment(@user, tool_call.name)

    # Track patterns for recommendations
    UserBehaviorTracker.record_tool_usage(@user, tool_call.name, @call_counts)
  end
end
```

## Performance Monitoring

Track tool performance for optimization:

```ruby
class ToolPerformanceMonitor
  def initialize
    @tool_timings = {}
  end

  def tool_call_callback
    proc do |tool_call|
      @tool_timings[tool_call.id] = Time.current
    end
  end

  def tool_result_callback
    proc do |result, tool_call_id|
      start_time = @tool_timings[tool_call_id]
      return unless start_time

      duration = Time.current - start_time

      # Log performance metrics
      ToolPerformanceMetric.create!(
        tool_name: extract_tool_name(tool_call_id),
        duration: duration,
        success: !result.is_a?(Hash) || !result[:error],
        result_size: calculate_result_size(result)
      )

      # Alert on slow tools
      if duration > 30.seconds
        Rails.logger.warn("Slow tool execution: #{duration.round(2)}s")
      end

      @tool_timings.delete(tool_call_id)
    end
  end

  private

  def calculate_result_size(result)
    result.to_s.bytesize
  rescue
    0
  end
end
```

## Testing Callbacks

Test callback functionality in your Rails tests:

```ruby
# test/services/tool_callback_test.rb
class ToolCallbackTest < ActiveSupport::TestCase
  def setup
    @user = users(:admin)
    @callback_handler = MonitoredChatService.new(@user)
  end

  test "tool call callback logs usage" do
    tool_call = OpenStruct.new(
      name: 'Weather',
      arguments: { city: 'London' },
      id: 'test_id'
    )

    assert_difference 'ToolUsageLog.count', 1 do
      @callback_handler.send(:handle_tool_call, tool_call)
    end

    log = ToolUsageLog.last
    assert_equal 'Weather', log.tool_name
    assert_equal({ city: 'London' }, log.arguments)
  end

  test "tool result callback updates log" do
    # Create initial log
    log = ToolUsageLog.create!(
      user: @user,
      tool_name: 'Weather',
      arguments: { city: 'London' },
      called_at: Time.current
    )

    @callback_handler.instance_variable_set(:@current_tool_log, log)

    result = { temperature: '22°C', condition: 'Sunny' }
    @callback_handler.send(:handle_tool_result, result)

    log.reload
    assert_equal result, log.result
    assert log.success
    assert log.completed_at
  end
end
```

## Important Considerations

### Callback Error Handling

- **Never raise exceptions in callbacks** - This breaks the conversation flow
- Always wrap callback code in error handling
- Log errors but allow the conversation to continue

### Performance Impact

- Keep callbacks lightweight and fast
- Use background jobs for heavy processing
- Cache expensive operations

### Data Privacy

- Be mindful of logging sensitive data in tool arguments
- Implement data retention policies for tool usage logs
- Consider user privacy preferences

## Next Steps

- Learn about [Halting](tools-halting.md) - controlling tool execution flow and stopping operations
- Explore [MCP Integration](tools-mcp.md) - using Model Context Protocol with tools
- Review [Tool Basics](tools-basics.md) - foundational concepts and patterns