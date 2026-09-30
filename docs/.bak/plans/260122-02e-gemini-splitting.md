# Gemini Hallucinated Tool Results: Final Implementation

**Date**: 2026-01-23
**Feature**: Execute hallucinated tool calls from Gemini, then strip from content
**Status**: Ready for implementation
**Revision**: 2e (Final - balances DHH feedback with project architecture)

## Executive Summary

Gemini models hallucinate tool results without actually invoking tools. The message content contains what appears to be a tool response:

```
{success: true, memory_type: "journal", content: "I lost track of..."}You saw right through me.
```

But investigation reveals:
- `tools_used` is empty `[]` on these messages
- `on_tool_call` never fired
- The memories were **never saved** to the database
- RubyLLM did not recognize these as tool calls

**Pattern analysis (41 messages)**:
- **36x save_memory** (journal/core): Tool did NOT execute → need RECOVERY
- **5x whiteboard** (`board_updated`): Tool DID execute → just need STRIPPING

**Important**: Gemini uses JavaScript-style unquoted keys (`{success: true}` not `{"success": true}`). The parsing logic must handle this.

Simply stripping the JSON would **lose the user's intended data permanently**.

The solution: Parse the hallucinated result (handling JS-style keys), execute the actual tool, then strip the JSON.

## Design Philosophy

This spec balances two inputs:

1. **DHH's code review** (v2d feedback): Valid criticisms about scattered methods and string markers
2. **Project architecture** (from `/docs/architecture.md`): "No unnecessary abstractions - Avoid service objects"

The result:
- **Extract JSON parsing to a concern** - It is utility code, not Message-specific
- **Keep recovery logic on Message** - Fat models is the Rails way
- **No service objects** - Project architecture explicitly forbids them
- **No registry pattern** - Premature abstraction for one tool
- **No "(recovered)" marker** - Just use "save_memory" like normal execution

## Architecture Overview

```
Message with hallucinated tool result
         |
         v
ParsesJsonPrefix concern extracts JSON
         |
         v
Message#recover_hallucinated_tool_call! executes tool
         |
         v
Content cleaned, memory saved
```

## Implementation Steps

### Step 1: Create JSON Parsing Concern

- [ ] Create `app/models/concerns/parses_json_prefix.rb`

This concern provides pure utility methods for extracting JSON from the start of text content. It has no knowledge of messages, tools, or business logic.

```ruby
# app/models/concerns/parses_json_prefix.rb
module ParsesJsonPrefix
  extend ActiveSupport::Concern

  class_methods do
    # Extracts a complete JSON-like object from the start of text.
    # Returns the raw string (may be JS-style), or nil if no valid prefix exists.
    def extract_json_prefix(text)
      return nil if text.blank?

      text = text.to_s.lstrip
      return nil unless text.start_with?("{")

      depth = 0
      text.each_char.with_index do |char, i|
        depth += 1 if char == "{"
        depth -= 1 if char == "}"
        if depth.zero?
          json_str = text[0..i]
          remaining = text[(i + 1)..].lstrip
          # Only return if there's content after the JSON
          return remaining.present? ? json_str : nil
        end
      end

      nil
    end

    # Parses a JSON-like string, handling Gemini's JS-style unquoted keys.
    # Converts {success: true} to {"success": true} before parsing.
    def parse_json_like(text)
      return nil if text.blank?

      # First try standard JSON
      JSON.parse(text)
    rescue JSON::ParserError
      # Convert JS-style unquoted keys to valid JSON
      # Pattern: word followed by colon (not inside quotes)
      normalized = text.gsub(/(\{|,)\s*([a-z_][a-z0-9_]*)\s*:/i, '\1"\2":')
      JSON.parse(normalized)
    rescue JSON::ParserError
      nil
    end

    # Strips a JSON prefix from text, returning the remaining content.
    # If no JSON prefix exists or content would be empty, returns original text.
    def strip_json_prefix(text)
      return text if text.blank?

      text = text.to_s.lstrip
      return text unless text.start_with?("{")

      depth = 0
      text.each_char.with_index do |char, i|
        depth += 1 if char == "{"
        depth -= 1 if char == "}"
        if depth.zero?
          remaining = text[(i + 1)..].lstrip
          return remaining.presence || text
        end
      end

      text
    end
  end
end
```

### Step 2: Add Recovery Logic to Message Model

- [ ] Include the concern and add recovery methods to `app/models/message.rb`

```ruby
class Message < ApplicationRecord
  include ParsesJsonPrefix
  # ... existing includes ...

  # Detects messages with hallucinated tool results that need recovery.
  # Returns true if:
  # - Message is from an assistant with an agent
  # - No tools were actually used
  # - Content starts with a parseable JSON object
  # - JSON matches known hallucinated tool result patterns
  def has_hallucinated_tool_result?
    return false unless role == "assistant" && agent_id.present?
    return false if used_tools?

    json_str = self.class.extract_json_prefix(content)
    return false unless json_str

    data = self.class.parse_json_like(json_str)
    return false unless data

    recognizes_hallucinated_tool?(data)
  end

  # Recovers a hallucinated tool call by executing the actual tool,
  # then cleaning up the message content.
  # Returns the created record (e.g., AgentMemory) on success, false otherwise.
  def recover_hallucinated_tool_call!
    return false unless role == "assistant" && agent_id.present?
    return false if used_tools?

    json_str = self.class.extract_json_prefix(content)
    return false unless json_str

    data = self.class.parse_json_like(json_str)
    return false unless data

    data = data.transform_keys(&:to_sym)
    return false unless recognizes_hallucinated_tool?(data)

    execute_hallucinated_tool_recovery!(data)
  end

  private

  # Pattern matching for known hallucinated tool results.
  # Add new patterns here as they are discovered.
  def recognizes_hallucinated_tool?(data)
    data = data.transform_keys(&:to_sym) if data.is_a?(Hash)

    case data
    in { success: true, memory_type: String, content: String }
      AgentMemory.memory_types.key?(data[:memory_type])
    else
      false
    end
  end

  # Executes recovery for the detected tool type.
  # Each case corresponds to a pattern in recognizes_hallucinated_tool?
  def execute_hallucinated_tool_recovery!(data)
    case data
    in { success: true, memory_type:, content: memory_content }
      recover_save_memory!(memory_type:, content: memory_content)
    else
      false
    end
  end

  def recover_save_memory!(memory_type:, content:)
    agent = Agent.find_by(id: agent_id)
    return false unless agent

    transaction do
      memory = agent.memories.create!(
        content: content.to_s.strip,
        memory_type: memory_type
      )

      update!(
        content: self.class.strip_json_prefix(self.content),
        tools_used: [ "save_memory" ]
      )

      memory
    end
  end
end
```

### Step 3: Integrate into StreamsAiResponse

- [ ] Update `app/jobs/concerns/streams_ai_response.rb` to use the concern for content extraction and trigger recovery

```ruby
module StreamsAiResponse
  extend ActiveSupport::Concern
  include ParsesJsonPrefix

  # ... existing code ...

  def finalize_message!(ruby_llm_message)
    return unless @ai_message

    flush_all_buffers

    thinking_content = ruby_llm_message.thinking.presence || @thinking_accumulated.presence

    content = extract_message_content(ruby_llm_message.content)
    if content.blank?
      fallback_content = @content_accumulated.presence || @ai_message.reload.content
      if fallback_content.present?
        Rails.logger.warn "RubyLLM content was blank, using fallback content (#{fallback_content.length} chars)"
        content = fallback_content
      end
    end

    # Check for empty response which may indicate content filtering
    if content.blank? && ruby_llm_message.output_tokens.to_i == 0
      content = handle_empty_response(ruby_llm_message)
    end

    @ai_message.update!({
      content: content,
      thinking: thinking_content,
      model_id_string: ruby_llm_message.model_id,
      input_tokens: ruby_llm_message.input_tokens,
      output_tokens: ruby_llm_message.output_tokens,
      tools_used: @tools_used.uniq
    })

    # Recover hallucinated tool calls (Gemini bug workaround)
    recover_hallucinated_tool_calls!

    # Queue content moderation for the completed assistant message
    ModerateMessageJob.perform_later(@ai_message) if @ai_message.content.present?
  end

  private

  def recover_hallucinated_tool_calls!
    return unless @ai_message&.agent_id.present?
    return if @tools_used.any?

    if @ai_message.recover_hallucinated_tool_call!
      Rails.logger.info "Recovered hallucinated tool call for Message #{@ai_message.id}"
    end
  end

  def handle_empty_response(ruby_llm_message)
    Rails.logger.warn "LLM returned empty response (0 output tokens)"
    Rails.logger.warn "Raw response: #{ruby_llm_message.raw.inspect}"

    raw = ruby_llm_message.raw
    raw = raw.is_a?(Hash) ? raw : {}

    finish_reason = raw.dig("candidates", 0, "finishReason") ||
                    raw.dig("choices", 0, "finish_reason")
    block_reason = raw.dig("promptFeedback", "blockReason") ||
                   raw.dig("candidates", 0, "finishReason")

    if block_reason == "SAFETY" || finish_reason == "SAFETY"
      Rails.logger.warn "Response blocked due to safety filters"
      "_The AI was unable to respond due to content safety filters. Try rephrasing your message or starting a new conversation._"
    elsif finish_reason.present? && finish_reason != "STOP"
      Rails.logger.warn "Unusual finish reason: #{finish_reason}"
      "_The AI was unable to complete its response (reason: #{finish_reason}). Please try again._"
    else
      "_The AI returned an empty response. This may be due to content filtering or a temporary issue. Please try again._"
    end
  end

  # ... rest of existing code unchanged ...
end
```

### Step 4: Add Rake Task for Historical Messages

- [ ] Create `lib/tasks/messages.rake`

```ruby
namespace :messages do
  desc "Recover hallucinated tool calls from Gemini messages"
  task recover_hallucinated_tools: :environment do
    recovered = 0
    skipped = 0

    Message.where(role: "assistant")
           .where("content LIKE '{%'")
           .where.not(agent_id: nil)
           .find_each do |message|

      if message.has_hallucinated_tool_result?
        if message.recover_hallucinated_tool_call!
          recovered += 1
          print "."
        else
          skipped += 1
          print "?"
        end
      end
    end

    puts "\nRecovered #{recovered} hallucinated tool calls."
    puts "Skipped #{skipped} (could not recover)." if skipped > 0
  end

  desc "Dry run: show messages with hallucinated tool results"
  task recover_hallucinated_tools_dry_run: :environment do
    recoverable = 0

    Message.where(role: "assistant")
           .where("content LIKE '{%'")
           .where.not(agent_id: nil)
           .find_each do |message|

      next unless message.has_hallucinated_tool_result?

      json_str = Message.extract_json_prefix(message.content)
      data = JSON.parse(json_str, symbolize_names: true)

      puts "\nMessage #{message.id}"
      puts "  Agent: #{message.agent&.name}"
      puts "  Memory type: #{data[:memory_type]}"
      puts "  Content preview: #{data[:content].to_s.truncate(80)}"
      puts "  Remaining text: #{Message.strip_json_prefix(message.content).truncate(80)}"
      recoverable += 1
    end

    puts "\n#{recoverable} messages can be recovered."
  end
end
```

### Step 5: Add Tests

- [ ] Add tests to `test/models/concerns/parses_json_prefix_test.rb`

```ruby
require "test_helper"

class ParsesJsonPrefixTest < ActiveSupport::TestCase
  # Create a test class that includes the concern
  class TestParser
    extend ParsesJsonPrefix::ClassMethods
  end

  test "extract_json_prefix extracts leading JSON when followed by text" do
    content = '{"success": true, "content": "test"}Hello world'
    assert_equal '{"success": true, "content": "test"}', TestParser.extract_json_prefix(content)
  end

  test "extract_json_prefix extracts JS-style JSON when followed by text" do
    content = '{success: true, memory_type: "journal"}Response text'
    assert_equal '{success: true, memory_type: "journal"}', TestParser.extract_json_prefix(content)
  end

  test "extract_json_prefix handles nested braces" do
    content = '{"data": {"nested": "value"}}Remaining text'
    assert_equal '{"data": {"nested": "value"}}', TestParser.extract_json_prefix(content)
  end

  test "extract_json_prefix returns nil for JSON-only content" do
    content = '{"success": true}'
    assert_nil TestParser.extract_json_prefix(content)
  end

  test "extract_json_prefix returns nil for non-JSON content" do
    content = "Just a normal message"
    assert_nil TestParser.extract_json_prefix(content)
  end

  test "extract_json_prefix returns nil for blank content" do
    assert_nil TestParser.extract_json_prefix(nil)
    assert_nil TestParser.extract_json_prefix("")
    assert_nil TestParser.extract_json_prefix("   ")
  end

  test "extract_json_prefix handles whitespace before JSON" do
    content = '  {"key": "value"}Text after'
    assert_equal '{"key": "value"}', TestParser.extract_json_prefix(content)
  end

  test "parse_json_like parses standard JSON" do
    json = '{"success": true, "content": "test"}'
    result = TestParser.parse_json_like(json)
    assert_equal true, result["success"]
    assert_equal "test", result["content"]
  end

  test "parse_json_like parses JS-style unquoted keys" do
    json = '{success: true, memory_type: "journal", content: "test memory"}'
    result = TestParser.parse_json_like(json)
    assert_equal true, result["success"]
    assert_equal "journal", result["memory_type"]
    assert_equal "test memory", result["content"]
  end

  test "parse_json_like handles nested objects with unquoted keys" do
    json = '{success: true, data: {nested: "value"}}'
    result = TestParser.parse_json_like(json)
    assert_equal true, result["success"]
    assert_equal "value", result["data"]["nested"]
  end

  test "parse_json_like returns nil for invalid content" do
    assert_nil TestParser.parse_json_like(nil)
    assert_nil TestParser.parse_json_like("")
    assert_nil TestParser.parse_json_like("not json at all")
  end

  test "strip_json_prefix removes leading JSON" do
    content = '{"success": true}Hello world'
    assert_equal "Hello world", TestParser.strip_json_prefix(content)
  end

  test "strip_json_prefix removes JS-style JSON" do
    content = '{success: true, memory_type: "journal"}Response text'
    assert_equal "Response text", TestParser.strip_json_prefix(content)
  end

  test "strip_json_prefix returns original if no JSON prefix" do
    content = "Just a normal message"
    assert_equal content, TestParser.strip_json_prefix(content)
  end

  test "strip_json_prefix returns original if JSON is entire content" do
    content = '{"success": true}'
    assert_equal content, TestParser.strip_json_prefix(content)
  end

  test "strip_json_prefix handles whitespace" do
    content = '  {"key": "value"}  Text after  '
    assert_equal "Text after", TestParser.strip_json_prefix(content)
  end
end
```

- [ ] Add tests to `test/models/message_test.rb`

```ruby
# Add these tests to the existing message_test.rb

test "has_hallucinated_tool_result? detects unexecuted save_memory calls with JS-style JSON" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.agent = agent
  message.tools_used = []
  message.content = '{success: true, memory_type: "journal", content: "Test memory"}Response text'

  assert message.has_hallucinated_tool_result?
end

test "has_hallucinated_tool_result? detects standard JSON too" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.agent = agent
  message.tools_used = []
  message.content = '{"success": true, "memory_type": "journal", "content": "Test memory"}Response text'

  assert message.has_hallucinated_tool_result?
end

test "has_hallucinated_tool_result? returns false when tools_used is populated" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.agent = agent
  message.tools_used = ["save_memory"]
  message.content = '{success: true, memory_type: "journal", content: "Test memory"}Response text'

  refute message.has_hallucinated_tool_result?
end

test "has_hallucinated_tool_result? returns false for invalid memory_type" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.agent = agent
  message.tools_used = []
  message.content = '{success: true, memory_type: "invalid_type", content: "Test"}Response'

  refute message.has_hallucinated_tool_result?
end

test "has_hallucinated_tool_result? returns false without agent" do
  message = messages(:assistant_message)
  message.agent = nil
  message.tools_used = []
  message.content = '{success: true, memory_type: "journal", content: "Test"}Response'

  refute message.has_hallucinated_tool_result?
end

test "has_hallucinated_tool_result? returns false for whiteboard results (already executed)" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.agent = agent
  message.tools_used = []
  message.content = '{type: "board_updated", board_id: "abc123"}Response text'

  refute message.has_hallucinated_tool_result?
end

test "recover_hallucinated_tool_call! creates memory and cleans content with JS-style JSON" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.update!(
    agent: agent,
    tools_used: [],
    content: '{success: true, memory_type: "journal", content: "I learned something important"}Response text'
  )

  initial_memory_count = agent.memories.count

  result = message.recover_hallucinated_tool_call!

  assert result.is_a?(AgentMemory)
  assert_equal initial_memory_count + 1, agent.memories.count
  assert_equal "Response text", message.reload.content
  assert_equal ["save_memory"], message.tools_used

  memory = agent.memories.last
  assert_equal "I learned something important", memory.content
  assert_equal "journal", memory.memory_type
end

test "recover_hallucinated_tool_call! works with core memory type" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.update!(
    agent: agent,
    tools_used: [],
    content: '{success: true, memory_type: "core", content: "My favorite color is blue"}Text'
  )

  result = message.recover_hallucinated_tool_call!

  assert result.is_a?(AgentMemory)
  assert_equal "core", result.memory_type
end

test "recover_hallucinated_tool_call! returns false without agent" do
  message = messages(:assistant_message)
  message.update!(
    agent: nil,
    tools_used: [],
    content: '{success: true, memory_type: "journal", content: "Test"}Response'
  )

  refute message.recover_hallucinated_tool_call!
end

test "recover_hallucinated_tool_call! returns false when tools already used" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.update!(
    agent: agent,
    tools_used: ["some_tool"],
    content: '{success: true, memory_type: "journal", content: "Test"}Response'
  )

  initial_memory_count = agent.memories.count
  refute message.recover_hallucinated_tool_call!
  assert_equal initial_memory_count, agent.memories.count
end

test "recover_hallucinated_tool_call! handles whitespace in content" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.update!(
    agent: agent,
    tools_used: [],
    content: '  {success: true, memory_type: "journal", content: "  Needs trimming  "}  Response  '
  )

  result = message.recover_hallucinated_tool_call!

  assert result.is_a?(AgentMemory)
  assert_equal "Needs trimming", result.content
  assert_equal "Response", message.reload.content
end
```

## File Changes Summary

| File | Change |
|------|--------|
| `app/models/concerns/parses_json_prefix.rb` | **New** - JSON parsing utility concern |
| `app/models/message.rb` | Add `include ParsesJsonPrefix`, `has_hallucinated_tool_result?`, `recover_hallucinated_tool_call!`, private helpers |
| `app/jobs/concerns/streams_ai_response.rb` | Add `include ParsesJsonPrefix`, extract `handle_empty_response`, add `recover_hallucinated_tool_calls!` |
| `lib/tasks/messages.rake` | **New** - Rake tasks for historical recovery |
| `test/models/concerns/parses_json_prefix_test.rb` | **New** - Concern tests |
| `test/models/message_test.rb` | Add recovery tests |

## Why This Design

### Accepted from DHH Review

1. **Concern for JSON parsing**: The parsing logic is genuinely utility code with no knowledge of messages or tools. It belongs in a concern that can be included by anything that needs it.

2. **Remove "(recovered)" marker**: Just use "save_memory" like normal execution. If we need to track recovery status later, that is a database column, not a string suffix.

3. **Cleaner code organization**: The scattered class methods (`strip_tool_result_prefix`, `extract_json_prefix`) are consolidated into a single concern with clear purpose.

### Rejected from DHH Review

1. **Service objects**: The project architecture explicitly says "No unnecessary abstractions - Avoid service objects". Recovery logic belongs on the model.

2. **Registry pattern**: Premature abstraction. We have one tool exhibiting this behavior. The simple `case` statement with pattern matching is extensible if needed, without building infrastructure for a problem that may not grow.

3. **Separate recoverer classes**: Adds complexity without benefit for a single tool type.

### The Rails Way

This design follows the project's stated philosophy:

- **Fat models, skinny controllers**: Recovery logic lives on Message
- **Concerns for shared behavior**: JSON parsing is extracted because it is genuinely reusable
- **No unnecessary abstractions**: No service objects, no registries, no factory patterns

## Extensibility

If additional hallucinated tools are discovered, the pattern is simple:

```ruby
def recognizes_hallucinated_tool?(data)
  case data
  in { success: true, memory_type: String, content: String }
    AgentMemory.memory_types.key?(data[:memory_type])
  in { success: true, search_query: String, results: Array }
    # Future: hypothetical search tool
    true
  else
    false
  end
end

def execute_hallucinated_tool_recovery!(data)
  case data
  in { success: true, memory_type:, content: }
    recover_save_memory!(memory_type:, content:)
  in { success: true, search_query:, results: }
    # Future: hypothetical search tool recovery
    recover_search_tool!(query: search_query, results:)
  end
end
```

This is YAGNI-compliant: we build the minimal solution that solves the actual problem, with a clear path to extension if needed.

## Deployment Steps

1. Deploy the code changes
2. Run `rails messages:recover_hallucinated_tools_dry_run` to review
3. Run `rails messages:recover_hallucinated_tools` to fix historical messages
4. Delete `lib/tasks/messages.rake` after historical fix is complete

## Testing Strategy

1. **Unit tests for ParsesJsonPrefix concern**: Pure string manipulation, easy to test
2. **Unit tests for Message recovery**: Pattern detection and execution
3. **Integration via rake task dry run**: Verify against real production data patterns
4. **Manual testing**: Create a message with Gemini that triggers save_memory

Run: `rails test test/models/concerns/parses_json_prefix_test.rb test/models/message_test.rb`
