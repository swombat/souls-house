# RubyLLM Tools - Halting and Control

## Overview

RubyLLM provides mechanisms to control tool execution flow, including halting continuation, implementing timeouts, and limiting tool calls. These features help prevent runaway executions, manage resource usage, and maintain responsive applications.

## The `halt` Helper

The `halt` helper stops the LLM from continuing after your tool executes, skipping the AI's typical summary or commentary:

### Basic Halt Usage

```ruby
class SaveFileTool < RubyLLM::Tool
  description "Save content to a file"

  param :path, desc: "File path where content should be saved"
  param :content, desc: "Content to write to the file"

  def execute(path:, content:)
    # Validate the file path for security
    validate_file_path(path)

    # Write the file
    File.write(path, content)

    # Halt prevents the LLM from adding commentary
    halt "File saved successfully to #{path}"
  end

  private

  def validate_file_path(path)
    # Implement security checks
    safe_directories = [Rails.root.join('tmp'), Rails.root.join('public/uploads')]
    full_path = Pathname.new(path).expand_path

    unless safe_directories.any? { |dir| full_path.to_s.start_with?(dir.to_s) }
      raise "File path not allowed: #{path}"
    end
  end
end
```

### When to Use Halt

Use `halt` when you need to:

- **Skip unnecessary AI commentary** - For simple file operations or data saves
- **Provide direct responses** - When the tool result is the final answer
- **Prevent confusion** - When additional AI processing might be misleading

```ruby
class DirectResponseTool < RubyLLM::Tool
  description "Provides direct answers that don't need AI elaboration"

  param :query_type, desc: "Type of direct query"

  def execute(query_type:)
    case query_type
    when "server_status"
      status = check_server_status
      halt "Server status: #{status[:status]} - Uptime: #{status[:uptime]}"

    when "user_count"
      count = User.count
      halt "Total registered users: #{count}"

    when "system_time"
      halt "Current system time: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"

    else
      # Don't halt for complex queries that benefit from AI interpretation
      { error: "Unknown query type: #{query_type}" }
    end
  end
end
```

### When NOT to Use Halt

Avoid `halt` when:

- **AI summary adds value** - Complex operations that benefit from explanation
- **Error handling** - Let AI help interpret and explain errors
- **Multi-step operations** - When subsequent tools might be needed

```ruby
class ComplexAnalysisTool < RubyLLM::Tool
  description "Performs complex data analysis"

  param :dataset, desc: "Dataset to analyze"

  def execute(dataset:)
    results = perform_analysis(dataset)

    # DON'T halt here - let AI summarize and explain the results
    {
      analysis_complete: true,
      key_findings: results[:findings],
      statistical_summary: results[:stats],
      recommendations: results[:recommendations],
      data_quality_issues: results[:issues]
    }
  end
end
```

## Tool Call Limiting

Prevent excessive tool usage with call count limits:

### Basic Call Limiting

```ruby
class LimitedChat
  def initialize(max_calls: 10)
    @max_calls = max_calls
    @call_count = 0
  end

  def create_chat
    RubyLLM.chat(model: 'gpt-4')
      .with_tool(Weather)
      .with_tool(DatabaseQuery)
      .on_tool_call(&method(:check_call_limit))
  end

  private

  def check_call_limit(tool_call)
    @call_count += 1

    if @call_count > @max_calls
      Rails.logger.warn("Tool call limit exceeded: #{@call_count}/#{@max_calls}")

      # WARNING: Raising exception breaks conversation flow
      # Consider alternative approaches
      raise "Tool call limit exceeded (#{@max_calls} calls)"
    end

    Rails.logger.info("Tool call #{@call_count}/#{@max_calls}: #{tool_call.name}")
  end
end
```

### Better Alternative: Soft Limiting

Instead of hard limits that break conversations, use soft limits with warnings:

```ruby
class SmartCallLimiter
  def initialize(user, soft_limit: 20, hard_limit: 50)
    @user = user
    @soft_limit = soft_limit
    @hard_limit = hard_limit
    @call_count = 0
    @warnings_sent = 0
  end

  def create_chat
    RubyLLM.chat(model: 'gpt-4')
      .with_tool(EnhancedWeather)
      .with_tool(SmartDatabaseQuery)
      .on_tool_call(&method(:monitor_calls))
  end

  private

  def monitor_calls(tool_call)
    @call_count += 1

    case @call_count
    when @soft_limit
      send_soft_limit_warning
    when @hard_limit
      # Even here, prefer degraded service over broken conversation
      switch_to_limited_mode
    end

    log_usage(tool_call)
  end

  def send_soft_limit_warning
    Rails.logger.warn("User #{@user.id} approaching tool limit: #{@call_count}/#{@soft_limit}")

    # Notify user through separate channel
    NotificationService.send_warning(@user, :tool_usage_high)

    @warnings_sent += 1
  end

  def switch_to_limited_mode
    Rails.logger.warn("User #{@user.id} hit hard limit: #{@call_count}/#{@hard_limit}")

    # Switch to tools with built-in limitations
    # Don't break the conversation
    NotificationService.send_limit_reached(@user)
  end

  def log_usage(tool_call)
    ToolUsageTracker.record(@user, tool_call.name, @call_count)
  end
end
```

## Timeout Management

Implement timeouts to prevent hanging operations:

### Tool-Level Timeouts

```ruby
class TimeoutAwareTool < RubyLLM::Tool
  description "Demonstrates proper timeout handling"

  param :operation, desc: "Operation to perform"
  param :timeout, desc: "Timeout in seconds", type: :integer, required: false

  def execute(operation:, timeout: 30)
    begin
      Timeout.timeout(timeout) do
        perform_operation(operation)
      end
    rescue Timeout::Error
      # Return error instead of raising - let AI help user
      {
        error: "Operation timed out after #{timeout} seconds",
        suggestion: "Try a simpler operation or increase the timeout",
        operation: operation
      }
    end
  end

  private

  def perform_operation(operation)
    case operation
    when "quick"
      # Fast operation
      { result: "Quick operation completed", duration: 1 }

    when "slow"
      # Simulate slow operation
      sleep(45) # This will timeout with default 30s limit
      { result: "Slow operation completed", duration: 45 }

    when "external_api"
      make_external_api_call

    else
      { error: "Unknown operation: #{operation}" }
    end
  end

  def make_external_api_call
    # Use HTTP client with its own timeout
    response = Faraday.get('https://api.example.com/data') do |req|
      req.options.timeout = 15 # HTTP timeout
    end

    JSON.parse(response.body)
  rescue Faraday::TimeoutError
    { error: "External API timeout", suggestion: "The external service is slow. Try again later." }
  rescue => e
    { error: "API error: #{e.message}" }
  end
end
```

### Global Timeout Configuration

Configure timeouts at the RubyLLM level:

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.openai_api_key = Rails.application.credentials.openai_api_key

  # Request timeout - how long to wait for API response
  config.request_timeout = 120 # seconds (default: 120)

  # Retry configuration
  config.max_retries = 3                    # Retry attempts on failure
  config.retry_interval = 0.1               # Initial retry delay
  config.retry_backoff_factor = 2           # Exponential backoff
  config.retry_interval_randomness = 0.5    # Jitter to prevent thundering herd
end
```

### Per-Chat Timeout Management

```ruby
class TimeoutManagedChat
  def initialize(user)
    @user = user
    @start_time = Time.current
    @max_session_duration = user.premium? ? 1.hour : 15.minutes
  end

  def create_chat
    RubyLLM.chat(model: 'gpt-4')
      .with_tool(Weather)
      .on_tool_call(&method(:check_session_timeout))
      .on_new_message(&method(:check_response_timeout))
  end

  def ask(message)
    if session_expired?
      return "Session expired. Please start a new conversation."
    end

    @chat.ask(message)
  end

  private

  def check_session_timeout(tool_call)
    if session_expired?
      Rails.logger.warn("Session timeout for user #{@user.id}")

      # Don't break conversation, but warn user
      NotificationService.send_session_timeout_warning(@user)
    end
  end

  def check_response_timeout(message)
    # Monitor for long responses that might indicate issues
    response_start = Time.current

    # You could implement response-level timeouts here
    # This is just monitoring in this example
    Rails.logger.info("Response started for user #{@user.id}")
  end

  def session_expired?
    Time.current - @start_time > @max_session_duration
  end
end
```

## Graceful Degradation

Implement graceful degradation when limits are reached:

### Limited Mode Tools

```ruby
class LimitedWeatherTool < RubyLLM::Tool
  description "Weather tool with built-in limits for heavy users"

  param :city, desc: "City name"

  def execute(city:)
    # Simplified response for limited mode
    cached_weather = WeatherCache.find_by(city: city.downcase)

    if cached_weather && cached_weather.created_at > 1.hour.ago
      {
        city: city,
        temperature: cached_weather.temperature,
        condition: cached_weather.condition,
        note: "Using cached data due to usage limits"
      }
    else
      {
        error: "Weather data unavailable due to usage limits",
        suggestion: "Try again later or upgrade your plan for real-time data"
      }
    end
  end
end

class NormalWeatherTool < RubyLLM::Tool
  description "Full-featured weather tool"

  param :city, desc: "City name"

  def execute(city:)
    # Full API call with real-time data
    weather_data = WeatherService.fetch_current(city)

    {
      city: city,
      temperature: weather_data[:temp],
      condition: weather_data[:condition],
      humidity: weather_data[:humidity],
      wind_speed: weather_data[:wind],
      forecast: weather_data[:forecast]
    }
  rescue => e
    { error: "Weather service error: #{e.message}" }
  end
end
```

### Dynamic Tool Switching

```ruby
class AdaptiveChatService
  def initialize(user)
    @user = user
    @usage_monitor = UserUsageMonitor.new(user)
  end

  def create_chat
    tools = select_appropriate_tools

    chat = RubyLLM.chat(model: 'gpt-4')
    tools.each { |tool| chat.with_tool(tool) }

    chat.on_tool_call(&method(:monitor_usage))
  end

  private

  def select_appropriate_tools
    if @usage_monitor.over_limit?
      # Limited tools for users over limit
      [LimitedWeatherTool, CachedDatabaseQuery, SimplifiedReportGenerator]
    elsif @usage_monitor.approaching_limit?
      # Mixed mode - some limitations
      [NormalWeatherTool, OptimizedDatabaseQuery, StandardReportGenerator]
    else
      # Full-featured tools
      [EnhancedWeatherTool, FullDatabaseQuery, CompleteReportGenerator]
    end
  end

  def monitor_usage(tool_call)
    @usage_monitor.record_call(tool_call)

    # Switch tools mid-conversation if needed
    if @usage_monitor.just_hit_limit?
      Rails.logger.info("User #{@user.id} hit usage limit - switching to limited tools")
      NotificationService.send_limit_notification(@user)
    end
  end
end
```

## Emergency Stop Mechanisms

Implement emergency stops for problematic situations:

```ruby
class EmergencyStopTool < RubyLLM::Tool
  description "Emergency stop mechanism for runaway operations"

  def execute(**params)
    # Check for emergency conditions
    if system_overloaded?
      halt "System is currently overloaded. Please try again in a few minutes."
    end

    if user_behaving_suspiciously?
      halt "Unusual activity detected. Please contact support if you need assistance."
    end

    # Normal operation
    { status: "System operating normally" }
  end

  private

  def system_overloaded?
    # Check system metrics
    cpu_usage = SystemMetrics.current_cpu_usage
    memory_usage = SystemMetrics.current_memory_usage

    cpu_usage > 90 || memory_usage > 95
  end

  def user_behaving_suspiciously?
    # Check for suspicious patterns
    recent_calls = ToolUsageLog.where(
      user: current_user,
      called_at: 1.minute.ago..Time.current
    ).count

    recent_calls > 50 # Very high frequency
  end
end
```

## Best Practices

### Do's

- **Use soft limits with warnings** instead of hard breaks
- **Implement graceful degradation** when limits are reached
- **Provide helpful error messages** that guide users
- **Log usage patterns** for optimization
- **Use `halt` sparingly** - only when AI commentary isn't helpful

### Don'ts

- **Don't raise exceptions in callbacks** - This breaks conversation flow
- **Don't use overly restrictive limits** - This frustrates users
- **Don't halt on errors** - Let AI help interpret and explain
- **Don't implement hard stops without alternatives** - Always provide a path forward

### Monitoring and Alerting

```ruby
class ToolLimitMonitor
  def self.setup_alerts
    # Monitor for frequently hit limits
    alert_on_high_limit_hits

    # Monitor for users repeatedly hitting limits
    alert_on_problematic_users

    # Monitor system-wide tool usage patterns
    alert_on_unusual_patterns
  end

  private

  def self.alert_on_high_limit_hits
    limit_hits_today = ToolUsageLog.where(
      called_at: 1.day.ago..Time.current
    ).where("result LIKE ?", "%limit%").count

    if limit_hits_today > 100
      AdminNotificationService.send_high_limit_alert(limit_hits_today)
    end
  end
end
```

## Next Steps

- Explore [MCP Integration](tools-mcp.md) - using Model Context Protocol with tools
- Review [Tool Basics](tools-basics.md) - foundational concepts and patterns
- Learn about [Callbacks](tools-callbacks.md) - monitoring and responding to tool events