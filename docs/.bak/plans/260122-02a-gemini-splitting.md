# Gemini Tool Result Stripping Implementation Plan

**Date**: 2026-01-22
**Feature**: Strip malformed tool results from Gemini message content
**Status**: Ready for implementation
**Revision**: 2a (initial)

## Executive Summary

Gemini models incorrectly concatenate tool result JSON with response text, producing messages like:

```
{success: true, memory_type: "journal", content: "..."}You saw right through me.
```

The tool calls execute correctly - the problem is purely cosmetic: the tool result JSON appears in the message content. This plan addresses:

1. **Real-time cleanup**: Strip tool result JSON from content during `finalize_message!`
2. **Historical cleanup**: Model method to detect and fix malformed messages
3. **UI action**: Button for site admins to fix individual malformed messages
4. **Transparency**: Optionally store extracted tool results for debugging

The solution is minimal, Rails-idiomatic, and follows the existing patterns in the codebase.

## Architecture Overview

```
Streaming response from Gemini
         |
         v
enqueue_stream_chunk() accumulates content
         |
         v
finalize_message!() called with complete content
         |
         v
Message.strip_tool_results(content) removes JSON prefixes
         |
         v
Clean content stored in database
```

For historical messages:

```
Message#has_concatenated_tool_result? detects malformed content
         |
         v
Site admin clicks "Fix" button in UI
         |
         v
Message#strip_tool_result_prefix! cleans and saves
```

## Implementation Steps

### Step 1: Add Detection and Stripping Logic to Message Model

The core logic belongs in the Message model following Rails "fat models, skinny controllers" philosophy.

- [ ] Add `strip_tool_results` class method and `has_concatenated_tool_result?` instance method to `app/models/message.rb`

```ruby
class Message < ApplicationRecord
  # Existing code...

  # Patterns for tool results that Gemini incorrectly concatenates
  # Matches JSON-like structures at the start of content
  TOOL_RESULT_PATTERN = /\A\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/

  # Common tool result keys that indicate this is a tool result, not user JSON
  TOOL_RESULT_INDICATORS = %w[
    success error type memory_type content expires_around
    board_id board_created board_updated board_deleted
    query results total_results fetched_page redirect
    allowed_actions required_param
  ].freeze

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

  def has_concatenated_tool_result?
    return false if content.blank?
    return false unless role == "assistant"
    return false unless content.match?(TOOL_RESULT_PATTERN)

    json_match = content.match(TOOL_RESULT_PATTERN)
    return false unless json_match

    # Must have content after the JSON (otherwise it's just a tool result message)
    remaining = content[json_match[0].length..].strip
    return false if remaining.blank?

    self.class.send(:looks_like_tool_result?, json_match[0])
  end

  def strip_tool_result_prefix!
    return false unless has_concatenated_tool_result?

    cleaned_content = self.class.strip_tool_results(content)
    update!(content: cleaned_content)
  end

  # Existing code...
end
```

**Design Notes:**
- `TOOL_RESULT_PATTERN` uses a simple regex to find JSON-like structures at the start
- `TOOL_RESULT_INDICATORS` ensures we only strip actual tool results, not user-provided JSON
- The `while` loop handles multiple consecutive tool results (edge case but possible)
- `strip_tool_result_prefix!` returns `false` if nothing to clean (idempotent)
- The regex avoids deeply nested JSON to keep parsing simple

### Step 2: Integrate Stripping into finalize_message!

- [ ] Update `app/jobs/concerns/streams_ai_response.rb` to strip tool results during finalization

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

  Message.strip_tool_results(text)
end
```

**Design Notes:**
- Stripping happens at the natural content extraction point
- No additional method calls needed - it's seamlessly integrated
- The streaming content (`@content_accumulated`) is NOT modified - only the final RubyLLM content
- This means if fallback to `@content_accumulated` happens, it may still contain tool results (acceptable edge case)

### Step 3: Add Message JSON Attribute for Malformed Detection

- [ ] Add `has_malformed_tool_result` to `json_attributes` in `app/models/message.rb`

```ruby
json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                :completed, :created_at_formatted, :created_at_hour, :streaming,
                :files_json, :content_html, :tools_used, :tool_status,
                :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                :editable, :deletable,
                :moderation_flagged, :moderation_severity, :moderation_scores,
                :has_malformed_tool_result

def has_malformed_tool_result
  has_concatenated_tool_result?
end
```

### Step 4: Add Fix Endpoint for Individual Messages

- [ ] Add `fix_tool_result` action to `app/controllers/messages_controller.rb`

```ruby
class MessagesController < ApplicationController
  before_action :require_site_admin, only: [:fix_tool_result]

  # Existing actions...

  def fix_tool_result
    message = Message.find_by_obfuscated_id!(params[:id])

    if message.strip_tool_result_prefix!
      head :ok
    else
      head :unprocessable_entity
    end
  end

  private

  def require_site_admin
    head :forbidden unless Current.user&.site_admin?
  end
end
```

- [ ] Add route in `config/routes.rb`

```ruby
resources :messages, only: [:update, :destroy] do
  member do
    post :fix_tool_result
  end
end
```

### Step 5: Add Fix Button to Frontend

- [ ] Update `/app/frontend/pages/chats/show.svelte` to show fix button for malformed messages

Add the fix function:

```svelte
<script>
  // Existing code...

  async function fixToolResult(messageId) {
    try {
      const response = await fetch(`/messages/${messageId}/fix_tool_result`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
      });

      if (response.ok) {
        router.reload({ only: ['messages'], preserveScroll: true });
        successMessage = 'Message cleaned up';
        setTimeout(() => (successMessage = null), 3000);
      } else {
        errorMessage = 'Failed to fix message';
        setTimeout(() => (errorMessage = null), 3000);
      }
    } catch (error) {
      errorMessage = 'Failed to fix message';
      setTimeout(() => (errorMessage = null), 3000);
    }
  }
</script>
```

Add the button in the assistant message template (near the existing tools_used section):

```svelte
{#if message.tools_used && message.tools_used.length > 0}
  <div class="flex items-center gap-2 mt-3 pt-3 border-t border-border/50">
    <Globe size={14} class="text-muted-foreground" weight="duotone" />
    <div class="flex flex-wrap gap-1">
      {#each formatToolsUsed(message.tools_used) as tool}
        <Badge variant="secondary" class="text-xs">
          {tool}
        </Badge>
      {/each}
    </div>
  </div>
{/if}

{#if isSiteAdmin && message.has_malformed_tool_result}
  <div class="flex items-center gap-2 mt-2 pt-2 border-t border-border/50">
    <Button variant="outline" size="sm" onclick={() => fixToolResult(message.id)}>
      Fix malformed content
    </Button>
  </div>
{/if}
```

**Design Notes:**
- Button only visible to site admins
- Uses existing `isSiteAdmin` computed property
- Reloads messages after fix to show updated content
- Simple success/error feedback via existing toast system

### Step 6: Add Route Helper

- [ ] Add route helper to `/app/frontend/routes.js`

```javascript
export function fixToolResultPath(messageId) {
  return `/messages/${messageId}/fix_tool_result`;
}
```

Update the import and usage in `show.svelte` if desired (optional - inline URL also works).

### Step 7: Add Tests

- [ ] Add model tests in `test/models/message_test.rb`

```ruby
class MessageTest < ActiveSupport::TestCase
  # Existing tests...

  test "strip_tool_results removes tool result JSON from content start" do
    content = '{success: true, memory_type: "journal", content: "test"}You saw right through me.'
    result = Message.strip_tool_results(content)
    assert_equal "You saw right through me.", result
  end

  test "strip_tool_results handles properly formatted JSON" do
    content = '{"success": true, "memory_type": "journal"}Hello there.'
    result = Message.strip_tool_results(content)
    assert_equal "Hello there.", result
  end

  test "strip_tool_results preserves content without tool results" do
    content = "Just a normal message"
    result = Message.strip_tool_results(content)
    assert_equal "Just a normal message", content
  end

  test "strip_tool_results preserves user JSON that is not a tool result" do
    content = '{"user_data": "something"} Here is my message'
    result = Message.strip_tool_results(content)
    assert_equal content, result
  end

  test "strip_tool_results handles multiple consecutive tool results" do
    content = '{"success": true}{"type": "board_updated"}Actual message'
    result = Message.strip_tool_results(content)
    assert_equal "Actual message", result
  end

  test "strip_tool_results returns original if only tool result (no text)" do
    content = '{"success": true, "memory_type": "journal"}'
    result = Message.strip_tool_results(content)
    assert_equal content, result
  end

  test "strip_tool_results handles blank content" do
    assert_nil Message.strip_tool_results(nil)
    assert_equal "", Message.strip_tool_results("")
  end

  test "has_concatenated_tool_result? detects malformed content" do
    message = messages(:assistant_message)
    message.content = '{"success": true, "memory_type": "journal"}Response text'
    assert message.has_concatenated_tool_result?
  end

  test "has_concatenated_tool_result? returns false for user messages" do
    message = messages(:user_message)
    message.content = '{"success": true}Some text'
    assert_not message.has_concatenated_tool_result?
  end

  test "has_concatenated_tool_result? returns false for clean messages" do
    message = messages(:assistant_message)
    message.content = "Just a normal response"
    assert_not message.has_concatenated_tool_result?
  end

  test "has_concatenated_tool_result? returns false for tool-result-only messages" do
    message = messages(:assistant_message)
    message.content = '{"success": true, "memory_type": "journal"}'
    assert_not message.has_concatenated_tool_result?
  end

  test "strip_tool_result_prefix! cleans and saves message" do
    message = messages(:assistant_message)
    message.update!(content: '{"success": true, "memory_type": "journal"}Clean text')

    assert message.strip_tool_result_prefix!
    assert_equal "Clean text", message.reload.content
  end

  test "strip_tool_result_prefix! returns false if nothing to clean" do
    message = messages(:assistant_message)
    message.update!(content: "Already clean")

    assert_not message.strip_tool_result_prefix!
  end
end
```

- [ ] Add controller test in `test/controllers/messages_controller_test.rb`

```ruby
class MessagesControllerTest < ActionDispatch::IntegrationTest
  # Existing tests...

  test "fix_tool_result cleans malformed message for site admin" do
    sign_in users(:site_admin)
    message = messages(:assistant_message)
    message.update!(content: '{"success": true, "memory_type": "journal"}Clean text')

    post fix_tool_result_message_path(message.obfuscated_id)

    assert_response :ok
    assert_equal "Clean text", message.reload.content
  end

  test "fix_tool_result returns unprocessable_entity for already clean message" do
    sign_in users(:site_admin)
    message = messages(:assistant_message)
    message.update!(content: "Already clean")

    post fix_tool_result_message_path(message.obfuscated_id)

    assert_response :unprocessable_entity
  end

  test "fix_tool_result forbidden for non-admin" do
    sign_in users(:regular_user)
    message = messages(:assistant_message)

    post fix_tool_result_message_path(message.obfuscated_id)

    assert_response :forbidden
  end

  test "fix_tool_result forbidden for unauthenticated user" do
    message = messages(:assistant_message)

    post fix_tool_result_message_path(message.obfuscated_id)

    assert_response :unauthorized
  end
end
```

## File Changes Summary

| File | Change |
|------|--------|
| `app/models/message.rb` | Add `strip_tool_results`, `has_concatenated_tool_result?`, `strip_tool_result_prefix!`, update `json_attributes` |
| `app/jobs/concerns/streams_ai_response.rb` | Update `extract_message_content` to call `Message.strip_tool_results` |
| `app/controllers/messages_controller.rb` | Add `fix_tool_result` action and `require_site_admin` before filter |
| `config/routes.rb` | Add `post :fix_tool_result` to messages member routes |
| `app/frontend/pages/chats/show.svelte` | Add `fixToolResult` function and fix button UI |
| `app/frontend/routes.js` | Add `fixToolResultPath` helper (optional) |
| `test/models/message_test.rb` | Add tests for stripping logic |
| `test/controllers/messages_controller_test.rb` | Add tests for fix endpoint |

## Edge Cases and Error Handling

1. **Non-JSON prefix that looks like JSON**: The `looks_like_tool_result?` check ensures we only strip content that parses as JSON AND contains known tool result keys
2. **User intentionally starts message with JSON**: Only tool result keys trigger stripping - arbitrary JSON is preserved
3. **Multiple tool results concatenated**: The `while` loop handles this edge case
4. **Tool result with no following text**: Returns original content (it's just a tool result message, not malformed)
5. **Empty/blank content**: Handled gracefully, returns original
6. **Streaming fallback**: If RubyLLM content is blank and we fall back to `@content_accumulated`, the tool result may still be present (acceptable - rare edge case)
7. **Already cleaned message**: `strip_tool_result_prefix!` is idempotent - returns false, doesn't modify

## Testing Strategy

1. **Unit tests** for `Message.strip_tool_results` with various inputs
2. **Unit tests** for `Message#has_concatenated_tool_result?` detection
3. **Unit tests** for `Message#strip_tool_result_prefix!` cleanup
4. **Controller tests** for fix endpoint authorization and functionality
5. **Manual testing** with Gemini model to verify real-time cleanup

Run full test suite: `rails test`

## Alternatives Considered

### 1. Fix During Streaming
**Rejected**: Would add complexity to the hot path and require buffering to detect JSON boundaries. The current approach of fixing at finalization is simpler.

### 2. Store Extracted Tool Results Separately
**Deferred**: Could add a `last_tool_result` column later if needed for debugging. Current solution focuses on the core problem.

### 3. Frontend-Only Filtering
**Rejected**: The frontend already hides messages that start with `{`, but this is a workaround. Fixing at the source is cleaner.

### 4. Provider-Specific Handling
**Rejected**: While this is a Gemini-specific issue, the solution is generic and won't harm other providers. Simpler than conditional logic.

## Future Enhancements

1. **Batch fix rake task**: `rails messages:fix_malformed` to clean all historical messages
2. **Tool result storage**: Store extracted results in `last_tool_result` column for transparency
3. **Monitoring**: Track frequency of tool result stripping to identify if Gemini improves
