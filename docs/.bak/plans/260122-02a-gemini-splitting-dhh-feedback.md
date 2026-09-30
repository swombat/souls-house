# DHH-Style Code Review: Gemini Tool Result Stripping Implementation

**Date**: 2026-01-23
**Reviewer**: Claude (channeling DHH)
**Spec Reviewed**: `260122-02a-gemini-splitting.md`

---

## Overall Assessment

This spec is **mostly Rails-worthy** but suffers from classic over-engineering tendencies. The core problem is simple: Gemini concatenates tool result JSON with response text. The solution should be equally simple: strip it. Instead, this spec introduces a configurable allowlist of "tool result indicators," a while loop for "multiple consecutive tool results," and a site-admin-only UI button for historical cleanup.

The model methods are fine. The streaming integration is elegant. But the frontend additions, the new controller action, and the "transparency" concerns smell of premature abstraction. We are solving a cosmetic bug from a single provider with machinery designed to handle edge cases that may never occur.

Let us simplify.

---

## Critical Issues

### 1. The Regex is Fighting JSON, and JSON is Winning

```ruby
TOOL_RESULT_PATTERN = /\A\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/
```

This regex attempts to match "JSON-like structures" but explicitly "avoids deeply nested JSON." This is precisely the kind of half-measure that creates bugs. You cannot parse JSON with regex. Period. The regex will match `{foo: bar}` (invalid JSON) and fail on `{"a":{"b":{"c":1}}}` (valid JSON).

The spec acknowledges this by using `JSON.parse` as a fallback in `looks_like_tool_result?`. So the regex is not actually doing the JSON detection - it is just finding candidates. This is acceptable, but the comment should reflect reality.

**Verdict**: Acceptable, but rename the constant to `POTENTIAL_JSON_PREFIX_PATTERN` or similar. Do not pretend regex understands JSON.

### 2. The Tool Result Indicators List is a Maintenance Burden

```ruby
TOOL_RESULT_INDICATORS = %w[
  success error type memory_type content expires_around
  board_id board_created board_updated board_deleted
  query results total_results fetched_page redirect
  allowed_actions required_param
].freeze
```

Every new tool you add requires updating this list. This is the opposite of Rails philosophy. Convention over configuration means the system should work without needing to enumerate every possible tool response key.

**Better approach**: If the content starts with valid JSON followed by text that does not start with `{`, strip the JSON. Do not care what keys are in it. Tool results are JSON; human messages starting with JSON are vanishingly rare and will still be readable (minus the JSON prefix).

If you must have an allowlist, make it a blocklist of keys that indicate user-provided JSON (e.g., keys that are clearly not tool results). But honestly, just strip any leading JSON from assistant messages. The edge case of "user intentionally started their JSON reply with `{` followed by prose" is not worth protecting against.

### 3. The Site Admin Fix Button is Unnecessary Complexity

The spec proposes:
- A new controller action (`fix_tool_result`)
- A new route
- A new `before_action` filter
- A new frontend function
- A new UI button (conditionally visible)
- A new JSON attribute (`has_malformed_tool_result`)

All of this to fix a handful of historical messages that most users will never notice and that will stop occurring once the real-time fix is in place.

**The Rails Way**: Write a one-time rake task. Run it. Done.

```ruby
# lib/tasks/messages.rake
namespace :messages do
  desc "Fix malformed Gemini tool results in message content"
  task fix_malformed_tool_results: :environment do
    Message.where(role: "assistant")
           .where("content LIKE '{%'")
           .find_each do |message|
      if message.has_concatenated_tool_result?
        message.strip_tool_result_prefix!
        print "."
      end
    end
    puts " Done!"
  end
end
```

Run `rails messages:fix_malformed_tool_results` once. Delete the task. No ongoing maintenance. No UI complexity. No additional attack surface.

If you absolutely must have a UI (you do not), use the existing "edit message" functionality that is already in place.

### 4. The Frontend Already Hides This

Look at `show.svelte`, line 295:

```javascript
if (m.role === 'assistant' && m.content && m.content.trim().startsWith('{') && !m.streaming) return false;
```

The frontend already filters out assistant messages that start with `{`. This means:
1. Users do not see the problem
2. The only people who see it are site admins with "show all messages" enabled
3. The "fix button" is for site admins to fix messages they can only see because they enabled debug mode

This is solving a problem that does not exist for end users.

---

## Improvements Needed

### 1. Simplify the Model Methods

**Before (spec)**:
```ruby
class << self
  def strip_tool_results(content)
    return content if content.blank?
    stripped = content.to_s
    while (match = stripped.match(TOOL_RESULT_PATTERN))
      json_str = match[0]
      break unless looks_like_tool_result?(json_str)
      stripped = stripped[json_str.length..].lstrip
    end
    stripped.presence || content
  end

  private

  def looks_like_tool_result?(json_str)
    parsed = JSON.parse(json_str)
    return false unless parsed.is_a?(Hash)
    (parsed.keys.map(&:to_s) & TOOL_RESULT_INDICATORS).any?
  rescue JSON::ParserError
    false
  end
end
```

**After (simplified)**:
```ruby
class << self
  def strip_tool_result_prefix(content)
    return content if content.blank?

    text = content.to_s
    return text unless text.start_with?("{")

    # Find where the JSON ends by parsing progressively
    json_end = find_json_end(text)
    return text unless json_end

    remaining = text[json_end..].lstrip
    remaining.presence || text
  end

  private

  def find_json_end(text)
    # Try to parse JSON from the start, finding the longest valid JSON prefix
    (1..text.length).reverse_each do |i|
      JSON.parse(text[0...i])
      return i
    rescue JSON::ParserError
      next
    end
    nil
  end
end
```

Actually, that is still over-complicated. Here is the real Rails way:

```ruby
def self.strip_tool_result_prefix(content)
  return content if content.blank?

  text = content.to_s.lstrip
  return text unless text.start_with?("{")

  # Find the matching closing brace (simple bracket counting)
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
```

No JSON parsing. No allowlists. Just find the balanced braces and strip the JSON object. This handles nested objects correctly and fails gracefully on malformed input.

### 2. Remove the While Loop

The spec handles "multiple consecutive tool results" with a while loop. When does this actually happen? The spec says "(edge case but possible)." In practice, if this happens, you have bigger problems in your tool calling logic.

Do not write code for edge cases that "might possibly maybe occur." Write code for what actually happens. If multiple tool results become a real problem, handle it then.

### 3. The Detection Method Can Be Simpler

**Before**:
```ruby
def has_concatenated_tool_result?
  return false if content.blank?
  return false unless role == "assistant"
  return false unless content.match?(TOOL_RESULT_PATTERN)

  json_match = content.match(TOOL_RESULT_PATTERN)
  return false unless json_match

  remaining = content[json_match[0].length..].strip
  return false if remaining.blank?

  self.class.send(:looks_like_tool_result?, json_match[0])
end
```

**After**:
```ruby
def has_concatenated_tool_result?
  return false unless role == "assistant" && content&.start_with?("{")

  cleaned = self.class.strip_tool_result_prefix(content)
  cleaned != content && cleaned.present?
end
```

Use the stripping method itself to detect. DRY.

### 4. Integration Point is Correct

The spec correctly identifies `extract_message_content` as the integration point:

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

This is clean. This is Rails. One method, one place, automatic cleanup.

---

## What Works Well

1. **Model-based logic**: Putting `strip_tool_result_prefix` on Message is correct. Fat models, skinny controllers.

2. **Integration at finalization**: Cleaning up during `finalize_message!` rather than during streaming is the right call. Do not complicate the hot path.

3. **Idempotent instance method**: `strip_tool_result_prefix!` returning `false` when nothing changed is proper Rails convention.

4. **Test coverage plan**: The tests are comprehensive and test the right things.

---

## Refactored Version

Here is what the implementation should look like:

### Message Model (`app/models/message.rb`)

```ruby
class Message < ApplicationRecord
  # ... existing code ...

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

  # ... existing code ...
end
```

### Streaming Concern (`app/jobs/concerns/streams_ai_response.rb`)

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

### One-Time Cleanup Task (`lib/tasks/messages.rake`)

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

### Tests (`test/models/message_test.rb`)

```ruby
class MessageTest < ActiveSupport::TestCase
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
end
```

---

## Summary of Changes from Original Spec

| Original Spec | This Review |
|--------------|-------------|
| Complex regex with JSON parsing fallback | Simple brace-counting algorithm |
| Allowlist of 16+ tool result keys | No allowlist needed |
| While loop for multiple tool results | Single-pass cleanup |
| New controller action + route | Rake task for one-time cleanup |
| New frontend button for site admins | Nothing (frontend already hides these) |
| New JSON attribute | Nothing (use existing detection method) |
| ~150 lines of new code | ~40 lines of new code |

---

## Final Verdict

The spec author understands Rails conventions and has good instincts about where code belongs. The problem is scope creep and over-engineering for edge cases.

Strip the JSON. Do it in the model. Integrate at finalization. Run a rake task for historical data. Delete the rake task. Move on.

That is the Rails way.
