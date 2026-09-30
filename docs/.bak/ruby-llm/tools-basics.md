# RubyLLM Tools - Basics

## Overview

RubyLLM Tools bridge AI models with real-world functionality, allowing AI to delegate tasks it cannot perform directly. Tools enable your Rails application to extend AI capabilities with custom business logic, database operations, API calls, and more.

## What Are Tools?

Tools are Ruby classes that AI models can invoke during conversations to:

- Fetch real-time data (weather, stock prices, user data)
- Perform calculations or data processing
- Interact with databases and external APIs
- Execute specific business logic
- Generate files, images, or reports
- Access Rails models and application state

## Basic Tool Structure

Every RubyLLM tool inherits from `RubyLLM::Tool` and follows this pattern:

```ruby
class YourTool < RubyLLM::Tool
  description "Clear description of what this tool does"

  param :parameter_name, desc: "Parameter description", type: :string
  param :optional_param, desc: "Optional parameter", required: false

  def execute(parameter_name:, optional_param: nil)
    # Tool implementation logic here
    # Return result as string, hash, or RubyLLM::Content
  end
end
```

## Simple Example: Weather Tool

```ruby
class Weather < RubyLLM::Tool
  description "Gets current weather for a location"

  param :city, desc: "City name (e.g., 'London', 'New York')"
  param :country, desc: "Country code (e.g., 'GB', 'US')", required: false

  def execute(city:, country: nil)
    location = country ? "#{city}, #{country}" : city

    # In a real implementation, you'd call a weather API
    # For demo purposes, we'll return a mock response
    {
      location: location,
      temperature: "22°C",
      condition: "Sunny",
      humidity: "45%"
    }
  rescue => e
    { error: "Unable to fetch weather: #{e.message}" }
  end
end
```

## Parameter Types

RubyLLM supports several parameter types for validation and better AI understanding:

```ruby
class ExampleTool < RubyLLM::Tool
  description "Demonstrates different parameter types"

  param :name, desc: "User name", type: :string
  param :age, desc: "User age", type: :integer
  param :score, desc: "Score value", type: :number  # Float
  param :active, desc: "Whether user is active", type: :boolean
  param :tags, desc: "Array of tags", type: :array
  param :metadata, desc: "Object with key-value pairs", type: :object

  def execute(name:, age:, score:, active:, tags: [], metadata: {})
    {
      processed_user: name,
      calculated_score: score * age,
      status: active ? "Active" : "Inactive",
      tag_count: tags.length,
      metadata_keys: metadata.keys
    }
  end
end
```

## Rails Integration Example

Tools can access your Rails models and application logic:

```ruby
class UserProfile < RubyLLM::Tool
  description "Retrieves user profile information"

  param :user_id, desc: "User ID to look up", type: :integer

  def execute(user_id:)
    user = User.find_by(id: user_id)

    return { error: "User not found" } unless user

    {
      name: user.name,
      email: user.email,
      created_at: user.created_at.strftime("%B %d, %Y"),
      posts_count: user.posts.count,
      last_login: user.current_sign_in_at&.strftime("%B %d, %Y at %I:%M %p")
    }
  rescue => e
    { error: "Database error: #{e.message}" }
  end
end
```

## Tool Registration and Usage

### With Chat Objects

```ruby
# Create a chat and register tools
chat = RubyLLM.chat(model: 'gpt-4')
         .with_tool(Weather)
         .with_tool(UserProfile)

# Ask questions that might trigger tools
response = chat.ask("What's the weather like in Paris?")
# AI will automatically call the Weather tool

user_info = chat.ask("Can you get the profile for user ID 123?")
# AI will call the UserProfile tool
```

### With Rails Chat Records

```ruby
# Using persisted chat records (recommended for Rails apps)
chat_record = Chat.create!(model: 'gpt-4')
chat_record.with_tool(Weather)
chat_record.with_tool(UserProfile)

response = chat_record.ask("Show me user 456's profile and the weather in their city")
# AI can use both tools in sequence if needed
```

## Error Handling Best Practices

Always handle potential errors in your tools:

```ruby
class DatabaseQuery < RubyLLM::Tool
  description "Queries database for specific information"

  param :table, desc: "Table name to query"
  param :conditions, desc: "Query conditions as hash", type: :object

  def execute(table:, conditions:)
    # Validate table name to prevent SQL injection
    allowed_tables = %w[users posts comments]
    unless allowed_tables.include?(table)
      return { error: "Table '#{table}' is not allowed" }
    end

    # Use ActiveRecord to safely query
    model_class = table.singularize.camelize.constantize
    results = model_class.where(conditions).limit(10)

    {
      table: table,
      count: results.count,
      records: results.map(&:attributes)
    }
  rescue NameError
    { error: "Invalid table name: #{table}" }
  rescue ActiveRecord::StatementInvalid => e
    { error: "Invalid query: #{e.message}" }
  rescue => e
    { error: "Unexpected error: #{e.message}" }
  end
end
```

## Security Considerations

### Input Validation

```ruby
class FileReader < RubyLLM::Tool
  description "Reads file contents (restricted to safe directories)"

  param :filename, desc: "File to read"

  def execute(filename:)
    # Validate file path
    safe_dirs = [Rails.root.join('public'), Rails.root.join('tmp')]
    full_path = Rails.root.join(filename)

    unless safe_dirs.any? { |dir| full_path.to_s.start_with?(dir.to_s) }
      return { error: "File access denied: outside safe directories" }
    end

    unless File.exist?(full_path)
      return { error: "File not found: #{filename}" }
    end

    {
      filename: filename,
      content: File.read(full_path),
      size: File.size(full_path)
    }
  rescue => e
    { error: "Cannot read file: #{e.message}" }
  end
end
```

### Never Use Dangerous Methods

```ruby
# ❌ NEVER DO THIS - Security vulnerabilities
class BadTool < RubyLLM::Tool
  def execute(command:)
    system(command)  # ❌ Command injection risk
    eval(code)       # ❌ Code injection risk
    User.find_by_sql("SELECT * FROM users WHERE name = '#{name}'")  # ❌ SQL injection
  end
end

# ✅ DO THIS - Safe alternatives
class GoodTool < RubyLLM::Tool
  def execute(user_name:)
    # Use parameterized queries
    User.where(name: user_name)

    # Use allowlists for system commands
    allowed_commands = %w[ls pwd date]
    if allowed_commands.include?(command)
      `#{command}`  # Still risky, prefer specific methods
    end
  end
end
```

## Testing Tools

Tools are just Ruby classes, so they're easy to test:

```ruby
# test/tools/weather_test.rb
require 'test_helper'

class WeatherTest < ActiveSupport::TestCase
  def setup
    @tool = Weather.new
  end

  test "returns weather data for valid city" do
    result = @tool.execute(city: "London")

    assert result[:location].include?("London")
    assert result[:temperature]
    assert result[:condition]
  end

  test "handles missing city gracefully" do
    result = @tool.execute(city: "")

    assert result[:error]
  end

  test "includes country in location when provided" do
    result = @tool.execute(city: "London", country: "GB")

    assert_equal "London, GB", result[:location]
  end
end
```

## Debugging Tools

Enable debug output to see tool interactions:

```bash
# In development, set environment variable
export RUBYLLM_DEBUG=true

# Or in your Rails app
Rails.application.config.ruby_llm.debug = true
```

This will show:
- When tools are called
- What parameters are passed
- Tool execution results
- Any errors that occur

## Next Steps

- Learn about [Rich Content](tools-rich-content.md) - returning images, files, and complex data
- Understand [Tool Execution Flow](tools-execution-flow.md) - advanced patterns and error handling
- Explore [Chat Integration](tools-in-chat.md) - using tools in Rails chat contexts
- Set up [Callbacks](tools-callbacks.md) - monitoring and responding to tool events