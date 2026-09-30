# Gemini Hallucinated Tool Results: Parse, Execute, Clean

**Date**: 2026-01-23
**Feature**: Execute hallucinated tool calls from Gemini, then strip from content
**Status**: Ready for implementation
**Revision**: 2d (MAJOR revision based on new findings)

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

Simply stripping the JSON (as in spec 2c) would **lose the user's intended data permanently**.

The solution: Parse the hallucinated result to extract tool arguments, execute the actual tool, then strip the JSON.

## Architecture Overview

```
Message with hallucinated tool result
         |
         v
Parse JSON to extract tool arguments
         |
         v
Execute actual tool (e.g., SaveMemoryTool)
         |
         v
Strip JSON from content
         |
         v
Update message (content cleaned, tools_used populated)
```

## Key Insight: Hallucinated Results Contain Arguments

The hallucinated JSON matches the tool's return value, which includes the original arguments:

```json
{
  "success": true,
  "memory_type": "journal",      // <-- This is an argument!
  "content": "I lost track...",  // <-- This is an argument!
  "expires_around": "2026-01-27"
}
```

SaveMemoryTool's `success_response` echoes back `memory_type` and `content`, which are exactly the required parameters.

## Implementation Steps

### Step 1: Add Tool Extraction to Message Model

- [ ] Add `extract_hallucinated_tool_call` method to `app/models/message.rb`

```ruby
class Message < ApplicationRecord
  class << self
    def strip_tool_result_prefix(content)
      return content if content.blank?

      text = content.to_s.lstrip
      return text unless text.start_with?("{")

      depth = 0
      text.each_char.with_index do |char, i|
        depth += 1 if char == "{"
        depth -= 1 if char == "}"
        if depth == 0
          remaining = text[(i + 1)..].lstrip
          return remaining.presence || text
        end
      end

      text
    end

    def extract_json_prefix(content)
      return nil if content.blank?

      text = content.to_s.lstrip
      return nil unless text.start_with?("{")

      depth = 0
      text.each_char.with_index do |char, i|
        depth += 1 if char == "{"
        depth -= 1 if char == "}"
        if depth == 0
          json_str = text[0..i]
          remaining = text[(i + 1)..].lstrip
          return nil if remaining.blank?
          return json_str
        end
      end

      nil
    end
  end

  def has_hallucinated_tool_result?
    return false unless role == "assistant" && agent_id.present?
    return false if tools_used.present? && tools_used.any?

    json_str = self.class.extract_json_prefix(content)
    return false unless json_str

    data = JSON.parse(json_str)
    data["success"] == true && data["content"].present? && data["memory_type"].present?
  rescue JSON::ParserError
    false
  end

  def extract_hallucinated_save_memory_args
    return nil unless role == "assistant"

    json_str = self.class.extract_json_prefix(content)
    return nil unless json_str

    data = JSON.parse(json_str)
    return nil unless data["success"] == true

    content_arg = data["content"]
    memory_type = data["memory_type"]

    return nil unless content_arg.present? && memory_type.present?
    return nil unless AgentMemory.memory_types.key?(memory_type)

    { content: content_arg, memory_type: memory_type }
  rescue JSON::ParserError
    nil
  end
end
```

### Step 2: Add Recovery Method to Message Model

- [ ] Add `recover_hallucinated_tool_call!` method

```ruby
class Message < ApplicationRecord
  def recover_hallucinated_tool_call!
    return false unless agent_id.present?
    return false unless (args = extract_hallucinated_save_memory_args)

    agent = Agent.find_by(id: agent_id)
    return false unless agent

    transaction do
      memory = agent.memories.create!(
        content: args[:content].to_s.strip,
        memory_type: args[:memory_type]
      )

      update!(
        content: self.class.strip_tool_result_prefix(content),
        tools_used: (tools_used || []) + ["save_memory (recovered)"]
      )

      memory
    end
  end
end
```

### Step 3: Integrate into finalize_message!

- [ ] Update `extract_message_content` in `app/jobs/concerns/streams_ai_response.rb`

```ruby
def extract_message_content(content)
  text = case content
         when RubyLLM::Content
           content.text
         when Hash, Array
           content.to_json
         else
           content
         end

  Message.strip_tool_result_prefix(text)
end
```

- [ ] Add recovery logic to `finalize_message!` (after message update)

```ruby
def finalize_message!(ruby_llm_message)
  # ... existing code ...

  @ai_message.update!({
    content: content,
    thinking: thinking_content,
    model_id_string: ruby_llm_message.model_id,
    input_tokens: ruby_llm_message.input_tokens,
    output_tokens: ruby_llm_message.output_tokens,
    tools_used: @tools_used.uniq
  })

  # Recover hallucinated tool calls (Gemini bug)
  recover_hallucinated_tool_calls!

  # Queue content moderation for the completed assistant message
  ModerateMessageJob.perform_later(@ai_message) if @ai_message.content.present?
end

def recover_hallucinated_tool_calls!
  return unless @ai_message&.agent_id.present?
  return if @tools_used.any?

  if @ai_message.recover_hallucinated_tool_call!
    Rails.logger.info "Recovered hallucinated tool call for Message #{@ai_message.id}"
  end
end
```

### Step 4: Add Rake Task for Historical Messages

- [ ] Create `lib/tasks/messages.rake`

```ruby
namespace :messages do
  desc "Fix malformed Gemini tool results: parse, execute tools, clean content"
  task fix_tool_results: :environment do
    fixed = 0
    executed = 0

    Message.where(role: "assistant")
           .where("content LIKE '{%'")
           .where.not(agent_id: nil)
           .find_each do |message|

      if message.has_hallucinated_tool_result?
        if message.recover_hallucinated_tool_call!
          executed += 1
          print "X"
        else
          print "?"
        end
      elsif message.has_concatenated_tool_result?
        message.strip_tool_result_prefix!
        fixed += 1
        print "."
      end
    end

    puts "\nRecovered #{executed} hallucinated tool calls."
    puts "Stripped #{fixed} additional messages (tools already executed)."
  end

  desc "Dry run: show what would be fixed"
  task fix_tool_results_dry_run: :environment do
    recoverable = 0
    strippable = 0

    Message.where(role: "assistant")
           .where("content LIKE '{%'")
           .where.not(agent_id: nil)
           .find_each do |message|

      if message.has_hallucinated_tool_result?
        args = message.extract_hallucinated_save_memory_args
        puts "\nRecoverable: Message #{message.id}"
        puts "  Agent: #{message.agent&.name}"
        puts "  Memory type: #{args[:memory_type]}"
        puts "  Content preview: #{args[:content].truncate(100)}"
        recoverable += 1
      elsif message.has_concatenated_tool_result?
        puts "\nStrippable: Message #{message.id} (tool already executed)"
        strippable += 1
      end
    end

    puts "\n\nSummary:"
    puts "  #{recoverable} messages with hallucinated tool calls (will execute tools)"
    puts "  #{strippable} messages needing only content cleanup"
  end
end
```

### Step 5: Add Support Methods

- [ ] Add `has_concatenated_tool_result?` and `strip_tool_result_prefix!` (from 2c)

```ruby
class Message < ApplicationRecord
  def has_concatenated_tool_result?
    return false unless role == "assistant" && content&.lstrip&.start_with?("{")

    original_lstripped = content.lstrip
    cleaned = self.class.strip_tool_result_prefix(content)
    cleaned.length < original_lstripped.length && cleaned.present?
  end

  def strip_tool_result_prefix!
    return false unless has_concatenated_tool_result?
    update!(content: self.class.strip_tool_result_prefix(content))
  end
end
```

### Step 6: Add Tests

- [ ] Add tests to `test/models/message_test.rb`

```ruby
test "extract_json_prefix extracts leading JSON" do
  content = '{"success": true, "content": "test"}Hello world'
  assert_equal '{"success": true, "content": "test"}', Message.extract_json_prefix(content)
end

test "extract_json_prefix returns nil for JSON-only content" do
  content = '{"success": true}'
  assert_nil Message.extract_json_prefix(content)
end

test "extract_json_prefix returns nil for non-JSON content" do
  content = "Just a normal message"
  assert_nil Message.extract_json_prefix(content)
end

test "extract_hallucinated_save_memory_args parses valid hallucinated result" do
  message = messages(:assistant_message)
  message.content = '{"success": true, "memory_type": "journal", "content": "Test memory"}Response'

  args = message.extract_hallucinated_save_memory_args
  assert_equal "Test memory", args[:content]
  assert_equal "journal", args[:memory_type]
end

test "extract_hallucinated_save_memory_args returns nil for invalid memory_type" do
  message = messages(:assistant_message)
  message.content = '{"success": true, "memory_type": "invalid", "content": "Test"}Response'

  assert_nil message.extract_hallucinated_save_memory_args
end

test "has_hallucinated_tool_result? detects unexecuted tool calls" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.agent = agent
  message.tools_used = []
  message.content = '{"success": true, "memory_type": "journal", "content": "Test memory"}Response'

  assert message.has_hallucinated_tool_result?
end

test "has_hallucinated_tool_result? returns false when tools_used is populated" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.agent = agent
  message.tools_used = ["save_memory"]
  message.content = '{"success": true, "memory_type": "journal", "content": "Test memory"}Response'

  refute message.has_hallucinated_tool_result?
end

test "recover_hallucinated_tool_call! creates memory and cleans content" do
  message = messages(:assistant_message)
  agent = agents(:paulina)
  message.update!(
    agent: agent,
    tools_used: [],
    content: '{"success": true, "memory_type": "journal", "content": "I learned something"}Response text'
  )

  initial_memory_count = agent.memories.count

  result = message.recover_hallucinated_tool_call!

  assert result
  assert_equal initial_memory_count + 1, agent.memories.count
  assert_equal "Response text", message.reload.content
  assert_includes message.tools_used, "save_memory (recovered)"

  memory = agent.memories.last
  assert_equal "I learned something", memory.content
  assert_equal "journal", memory.memory_type
end

test "recover_hallucinated_tool_call! returns false without agent" do
  message = messages(:assistant_message)
  message.update!(
    agent: nil,
    content: '{"success": true, "memory_type": "journal", "content": "Test"}Response'
  )

  refute message.recover_hallucinated_tool_call!
end
```

## File Changes Summary

| File | Change |
|------|--------|
| `app/models/message.rb` | Add `strip_tool_result_prefix`, `extract_json_prefix`, `extract_hallucinated_save_memory_args`, `has_hallucinated_tool_result?`, `has_concatenated_tool_result?`, `strip_tool_result_prefix!`, `recover_hallucinated_tool_call!` |
| `app/jobs/concerns/streams_ai_response.rb` | Update `extract_message_content`, add `recover_hallucinated_tool_calls!` |
| `lib/tasks/messages.rake` | Fix task with dry-run option |
| `test/models/message_test.rb` | Add tests |

## What This Adds Over v2c

| Addition | Reason |
|----------|--------|
| `extract_json_prefix` | Need to parse the JSON separately before stripping |
| `extract_hallucinated_save_memory_args` | Parse hallucinated result to get tool arguments |
| `has_hallucinated_tool_result?` | Detect messages needing tool execution (not just cleanup) |
| `recover_hallucinated_tool_call!` | Execute the tool and clean up |
| Dry-run rake task | Preview before making changes |
| Agent check | Only process messages from agents (who have tools) |

## Why This is Necessary

Without this fix:
- User instructs agent to save a memory
- Gemini "thinks" it called the tool and generates a fake result
- RubyLLM never recognizes the tool call
- Memory is **never saved**
- Stripping the JSON loses the data permanently

With this fix:
- We detect the hallucinated result pattern
- Extract the intended arguments
- Actually execute SaveMemoryTool
- Clean up the message
- Memory is saved as intended

## Scope Limitation

This spec focuses on `SaveMemoryTool` because:
1. It is the most common case in production
2. The hallucinated result format matches its success response
3. The arguments (content, memory_type) are recoverable from the result

Other tools may need similar handling if this pattern emerges, but we solve the actual problem first.

## Deployment Steps

1. Deploy the code changes
2. Run `rails messages:fix_tool_results_dry_run` to review
3. Run `rails messages:fix_tool_results` to fix historical messages
4. Delete `lib/tasks/messages.rake` (one-time use)

## Testing Strategy

1. Unit tests for JSON extraction and parsing
2. Unit tests for hallucinated tool detection
3. Unit tests for tool recovery (with fixtures)
4. Integration test: create message with hallucinated content, verify memory is created
5. Manual testing with Gemini model

Run: `rails test test/models/message_test.rb`
