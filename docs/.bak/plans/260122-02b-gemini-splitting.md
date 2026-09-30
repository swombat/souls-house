# Gemini Tool Result Stripping Implementation Plan

**Date**: 2026-01-23
**Feature**: Strip malformed tool results from Gemini message content
**Status**: Ready for implementation
**Revision**: 2b (simplified per DHH feedback)

## Executive Summary

Gemini models incorrectly concatenate tool result JSON with response text:

```
{"success": true, "memory_type": "journal"}You saw right through me.
```

The solution is simple: strip any leading JSON from assistant messages using brace-counting. No allowlists, no regex, no frontend buttons.

## Architecture Overview

```
Streaming response from Gemini
         |
         v
finalize_message!() called with complete content
         |
         v
Message.strip_tool_result_prefix(text) removes JSON prefix
         |
         v
Clean content stored in database
```

For historical messages: one-time rake task.

## Implementation Steps

### Step 1: Add Stripping Logic to Message Model

- [ ] Add `strip_tool_result_prefix` class method to `app/models/message.rb`

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
  end

  def has_concatenated_tool_result?
    return false unless role == "assistant" && content&.lstrip&.start_with?("{")

    cleaned = self.class.strip_tool_result_prefix(content)
    cleaned != content && cleaned.present?
  end

  def strip_tool_result_prefix!
    return false unless has_concatenated_tool_result?
    update!(content: self.class.strip_tool_result_prefix(content))
  end
end
```

### Step 2: Integrate into finalize_message!

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

### Step 3: Add One-Time Cleanup Rake Task

- [ ] Create `lib/tasks/messages.rake`

```ruby
namespace :messages do
  desc "Strip malformed tool result prefixes from Gemini messages"
  task fix_tool_results: :environment do
    fixed = 0
    Message.where(role: "assistant")
           .where("content LIKE '{%'")
           .find_each do |message|
      if message.strip_tool_result_prefix!
        fixed += 1
        print "."
      end
    end
    puts "\nFixed #{fixed} messages."
  end
end
```

### Step 4: Add Tests

- [ ] Add tests to `test/models/message_test.rb`

```ruby
test "strip_tool_result_prefix removes leading JSON" do
  content = '{"success": true}Hello world'
  assert_equal "Hello world", Message.strip_tool_result_prefix(content)
end

test "strip_tool_result_prefix handles nested JSON" do
  content = '{"result": {"nested": true}}Response text'
  assert_equal "Response text", Message.strip_tool_result_prefix(content)
end

test "strip_tool_result_prefix preserves content without JSON prefix" do
  content = "Just a normal message"
  assert_equal content, Message.strip_tool_result_prefix(content)
end

test "strip_tool_result_prefix returns original if only JSON" do
  content = '{"success": true}'
  assert_equal content, Message.strip_tool_result_prefix(content)
end

test "strip_tool_result_prefix handles blank content" do
  assert_nil Message.strip_tool_result_prefix(nil)
  assert_equal "", Message.strip_tool_result_prefix("")
end

test "has_concatenated_tool_result? detects malformed assistant messages" do
  message = messages(:assistant_message)
  message.content = '{"success": true}Response text'
  assert message.has_concatenated_tool_result?
end

test "has_concatenated_tool_result? returns false for user messages" do
  message = messages(:user_message)
  message.content = '{"data": true}Some text'
  refute message.has_concatenated_tool_result?
end

test "has_concatenated_tool_result? returns false for JSON-only messages" do
  message = messages(:assistant_message)
  message.content = '{"success": true}'
  refute message.has_concatenated_tool_result?
end

test "strip_tool_result_prefix! cleans and saves" do
  message = messages(:assistant_message)
  message.update!(content: '{"success": true}Clean text')

  assert message.strip_tool_result_prefix!
  assert_equal "Clean text", message.reload.content
end

test "strip_tool_result_prefix! returns false when nothing to clean" do
  message = messages(:assistant_message)
  message.update!(content: "Already clean")

  refute message.strip_tool_result_prefix!
end
```

## File Changes Summary

| File | Change |
|------|--------|
| `app/models/message.rb` | Add `strip_tool_result_prefix`, `has_concatenated_tool_result?`, `strip_tool_result_prefix!` |
| `app/jobs/concerns/streams_ai_response.rb` | Update `extract_message_content` to call `Message.strip_tool_result_prefix` |
| `lib/tasks/messages.rake` | One-time cleanup task (delete after running) |
| `test/models/message_test.rb` | Add tests for stripping logic |

## What This Removes from v2a

Per DHH's feedback:

| Removed | Reason |
|---------|--------|
| `TOOL_RESULT_PATTERN` regex | Brace-counting is simpler and handles nesting correctly |
| `TOOL_RESULT_INDICATORS` allowlist | Maintenance burden; just strip any leading JSON |
| While loop for multiple tool results | Solve actual problems, not theoretical edge cases |
| Controller action + route | Unnecessary; use rake task |
| Frontend fix button | Frontend already hides these messages |
| `has_malformed_tool_result` JSON attribute | Not needed without UI button |

## Deployment Steps

1. Deploy the code changes
2. Run `rails messages:fix_tool_results` once
3. Delete `lib/tasks/messages.rake`

## Testing Strategy

1. Unit tests for `Message.strip_tool_result_prefix` with various inputs
2. Unit tests for `Message#has_concatenated_tool_result?` detection
3. Unit tests for `Message#strip_tool_result_prefix!` cleanup
4. Manual testing with Gemini model to verify real-time cleanup

Run: `rails test test/models/message_test.rb`
