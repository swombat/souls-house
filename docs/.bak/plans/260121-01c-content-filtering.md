# Implementation Plan: Content Moderation Display (v3 - Final)

**Date**: 2026-01-21
**Status**: Ready for Implementation
**Feature**: Visual moderation indicators for chat messages
**Revision**: Final version incorporating DHH's second round feedback

## Executive Summary

Add content moderation to all messages (user and assistant) using RubyLLM's moderation API. The system displays a warning icon next to flagged messages with severity-based colouring (orange for medium, red for high). Tapping the icon reveals a bottom sheet showing all categories with their scores.

This is an informational feature, not a blocking mechanism.

## Changes from v2

Applied DHH's second round feedback:

| Change | Before | After |
|--------|--------|-------|
| Severity levels | 3 (low/medium/high) | 2 (medium/high) |
| Threshold comparison | `> 0.5` | `>= 0.5` |
| Svelte `flagged` prop | Required | Removed (derived from `severity`) |
| Sorted scores | Function `sortedCategories()` | `$derived` value `sortedScores` |
| Job guard clause | Two separate returns | Single positive conditional |
| Constant name | `MODERATION_FLAG_THRESHOLD` | `MODERATION_THRESHOLD` |
| Callback method name | `should_moderate_on_create?` | `user_message_with_content?` |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Message Lifecycle                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  User Message Created ──► after_commit ──► ModerateMessageJob   │
│                                                                 │
│  AI Message Finalized ──► finalize_message! ──► enqueue job     │
│                                                                 │
│  ModerateMessageJob ──► RubyLLM.moderate() ──► update message   │
│                         │                                       │
│                         ▼                                       │
│                   broadcast_replace_to (real-time update)       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation Steps

### Phase 1: Database Migration

- [ ] Create migration to add moderation columns to messages table

**File**: `db/migrate/XXXXXX_add_moderation_to_messages.rb`

```ruby
class AddModerationToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :moderation_scores, :jsonb
    add_column :messages, :moderated_at, :datetime
  end
end
```

**Design Notes**:
- `moderation_scores`: Hash of `{ "sexual" => 0.01, "hate" => 0.85, ... }` - the confidence scores
- `moderated_at`: Timestamp for tracking when moderation occurred
- No redundant columns - `flagged?` is derived from scores

### Phase 2: Background Job

- [ ] Create ModerateMessageJob

**File**: `app/jobs/moderate_message_job.rb`

```ruby
class ModerateMessageJob < ApplicationJob
  queue_as :default

  retry_on RubyLLM::RateLimitError, wait: :polynomially_longer, attempts: 5
  retry_on RubyLLM::Error, wait: 5.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(message)
    return unless message.content.present? && message.moderated_at.nil?

    result = RubyLLM.moderate(message.content)
    message.update!(moderation_scores: result.category_scores, moderated_at: Time.current)
  end
end
```

**Design Notes**:
- Single positive guard clause reads as: "Return unless the message has content and hasn't been moderated"
- Retry on rate limits with backoff
- Discard job if message deleted before processing (ActiveJob deserializes record)
- Only store scores - flagged state is derived

### Phase 3: Model Changes

- [ ] Update Message model with moderation methods and callbacks

**File**: `app/models/message.rb` (additions)

```ruby
class Message < ApplicationRecord
  MODERATION_THRESHOLD = 0.5

  json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                  :completed, :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :content_html, :tools_used, :tool_status,
                  :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                  :editable, :deletable,
                  :moderation_flagged, :moderation_severity, :moderation_scores

  after_commit :queue_moderation, on: :create, if: :user_message_with_content?

  def moderation_flagged?
    moderation_scores&.values&.any? { |score| score.to_f >= MODERATION_THRESHOLD }
  end

  alias_method :moderation_flagged, :moderation_flagged?

  def moderation_severity
    return unless moderation_flagged?
    moderation_scores.values.max.to_f >= 0.8 ? :high : :medium
  end

  private

  def user_message_with_content?
    role == "user" && content.present?
  end

  def queue_moderation
    ModerateMessageJob.perform_later(self)
  end
end
```

**Design Notes**:
- `MODERATION_THRESHOLD` is simpler than `MODERATION_FLAG_THRESHOLD`
- `moderation_flagged?` uses `>=` for semantic clarity ("50% or higher")
- `moderation_severity` returns only `:medium` or `:high` - no edge-case `:low`
- `user_message_with_content?` is more descriptive than `should_moderate_on_create?`
- Safe navigation (`&.`) handles nil scores elegantly
- User messages queue moderation on create (after_commit ensures transaction committed)
- Assistant messages are moderated via `finalize_message!` in the job concern

### Phase 4: Update AI Response Job Concern

- [ ] Add moderation queueing to finalize_message!

**File**: `app/jobs/concerns/streams_ai_response.rb` (modification to finalize_message!)

```ruby
def finalize_message!(ruby_llm_message)
  return unless @ai_message

  flush_all_buffers

  # ... existing content processing code ...

  @ai_message.update!({
    content: content,
    thinking: thinking_content,
    model_id_string: ruby_llm_message.model_id,
    input_tokens: ruby_llm_message.input_tokens,
    output_tokens: ruby_llm_message.output_tokens,
    tools_used: @tools_used.uniq
  })

  # Queue content moderation for the completed assistant message
  ModerateMessageJob.perform_later(@ai_message) if @ai_message.content.present?
end
```

### Phase 5: Frontend Component

- [ ] Create ModerationIndicator component

**File**: `app/frontend/lib/components/chat/ModerationIndicator.svelte`

```svelte
<script>
  import { WarningCircle } from 'phosphor-svelte';
  import * as Drawer from '$lib/components/shadcn/drawer/index.js';

  let { severity = null, scores = {} } = $props();
  let open = $state(false);

  const color = $derived(severity === 'high' ? 'text-red-500' : 'text-orange-500');

  const sortedScores = $derived(
    Object.entries(scores || {})
      .filter(([, score]) => score > 0.01)
      .sort(([, a], [, b]) => b - a)
  );

  function formatCategory(name) {
    return name.replace(/[/_-]/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
  }
</script>

{#if severity}
  <button onclick={() => open = true} class="p-1 rounded-full hover:bg-muted {color}">
    <WarningCircle size={18} weight="fill" />
  </button>

  <Drawer.Root bind:open direction="bottom">
    <Drawer.Content class="max-h-[60vh]">
      <Drawer.Header>
        <Drawer.Title class="flex items-center gap-2">
          <WarningCircle size={20} weight="fill" class={color} />
          Content Moderation
        </Drawer.Title>
      </Drawer.Header>

      <div class="p-4 space-y-3 overflow-y-auto">
        {#each sortedScores as [category, score]}
          <div class="flex items-center gap-3 p-2 rounded {score >= 0.5 ? 'bg-muted' : ''}">
            <div class="flex-1">
              <div class="flex items-center justify-between mb-1">
                <span class="text-sm font-medium">{formatCategory(category)}</span>
                <span class="text-xs text-muted-foreground">{(score * 100).toFixed(0)}%</span>
              </div>
              <div class="h-2 bg-muted rounded-full overflow-hidden">
                <div
                  class="h-full {score >= 0.8 ? 'bg-red-500' : score >= 0.5 ? 'bg-orange-500' : 'bg-gray-300'}"
                  style="width: {score * 100}%">
                </div>
              </div>
            </div>
          </div>
        {/each}
        <p class="text-xs text-muted-foreground mt-4 pt-4 border-t">
          Scores indicate likelihood of content matching each category.
        </p>
      </div>
    </Drawer.Content>
  </Drawer.Root>
{/if}
```

**Design Notes**:
- Only `severity` and `scores` props - no redundant `flagged` prop
- If `severity` is present, the message is flagged
- `sortedScores` uses `$derived` - idiomatic Svelte 5
- `color` uses `$derived` - reactive to severity changes
- Two severity colours only: orange (medium) and red (high)
- Bottom sheet drawer per user requirement (not popover)
- Score bar colours use `>= 0.5` to match backend threshold

### Phase 6: Update Chat Show Page

- [ ] Add ModerationIndicator to user message bubbles

**File**: `app/frontend/pages/chats/show.svelte`

Add import at top:
```svelte
import ModerationIndicator from '$lib/components/chat/ModerationIndicator.svelte';
```

In the user message section (after the timestamp div):
```svelte
<div class="text-xs text-muted-foreground text-right mt-1 flex items-center justify-end gap-2">
  {#if message.moderation_severity}
    <ModerationIndicator
      severity={message.moderation_severity}
      scores={message.moderation_scores} />
  {/if}
  <span class="group">
    <span class="hidden group-hover:inline-block">({formatDateTime(message.created_at, true)})</span>
    {formatTime(message.created_at)}
  </span>
  <!-- rest of existing content -->
</div>
```

- [ ] Add ModerationIndicator to assistant message bubbles

In the assistant message section (in the timestamp div):
```svelte
<div class="text-xs text-muted-foreground mt-1 flex items-center gap-2">
  {#if message.moderation_severity}
    <ModerationIndicator
      severity={message.moderation_severity}
      scores={message.moderation_scores} />
  {/if}
  {#if chat?.manual_responses && message.author_name}
    <span class="mr-1">{message.author_name} ·</span>
  {/if}
  <!-- rest of existing content -->
</div>
```

**Note**: Check for `moderation_severity` rather than `moderation_flagged` - severity presence indicates a flagged message.

### Phase 7: Colour Scheme Reference

| Severity | Icon Colour | Threshold |
|----------|-------------|-----------|
| Medium | `text-orange-500` | 0.5 <= max score < 0.8 |
| High | `text-red-500` | max score >= 0.8 |

Two severity levels only. Flagged content by definition has at least one category >= 0.5, so there is no "low" severity edge case.

### Phase 8: Real-time Updates

The existing Broadcastable concern on Message handles real-time updates automatically. When `ModerateMessageJob` calls `update!` on the message, the `broadcast_replace_to` callback will push the updated message (with moderation data) to the frontend via Turbo Streams.

No additional ActionCable configuration needed.

## Testing Strategy

- [ ] Unit tests for Message model

**File**: `test/models/message_test.rb` (additions)

```ruby
class MessageTest < ActiveSupport::TestCase
  test "moderation_flagged? returns false when scores are nil" do
    message = messages(:one)
    message.moderation_scores = nil
    assert_not message.moderation_flagged?
  end

  test "moderation_flagged? returns false when no scores meet threshold" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.3, "violence" => 0.2 }
    assert_not message.moderation_flagged?
  end

  test "moderation_flagged? returns true when any score meets threshold" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.5, "violence" => 0.2 }
    assert message.moderation_flagged?
  end

  test "moderation_flagged? returns true when score exceeds threshold" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.6, "violence" => 0.2 }
    assert message.moderation_flagged?
  end

  test "moderation_severity returns nil when not flagged" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.3 }
    assert_nil message.moderation_severity
  end

  test "moderation_severity returns :high for scores >= 0.8" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.85, "violence" => 0.2 }
    assert_equal :high, message.moderation_severity
  end

  test "moderation_severity returns :medium for scores 0.5-0.8" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.65, "violence" => 0.2 }
    assert_equal :medium, message.moderation_severity
  end

  test "moderation_severity returns :medium for score at exactly 0.5" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.5, "violence" => 0.2 }
    assert_equal :medium, message.moderation_severity
  end

  test "user message queues moderation on create" do
    chat = chats(:one)

    assert_enqueued_with(job: ModerateMessageJob) do
      chat.messages.create!(role: "user", content: "Test message", user: users(:one))
    end
  end

  test "assistant message does not queue moderation on create" do
    chat = chats(:one)

    assert_no_enqueued_jobs(only: ModerateMessageJob) do
      chat.messages.create!(role: "assistant", content: "Response")
    end
  end
end
```

- [ ] Job tests for ModerateMessageJob

**File**: `test/jobs/moderate_message_job_test.rb`

```ruby
require "test_helper"

class ModerateMessageJobTest < ActiveJob::TestCase
  setup do
    @message = messages(:one)
    @message.update!(content: "Test content", moderated_at: nil, moderation_scores: nil)
  end

  test "calls RubyLLM.moderate and updates message scores" do
    mock_result = OpenStruct.new(
      category_scores: { "hate" => 0.85, "violence" => 0.1 }
    )

    RubyLLM.stub(:moderate, mock_result) do
      ModerateMessageJob.perform_now(@message)
    end

    @message.reload
    assert_equal({ "hate" => 0.85, "violence" => 0.1 }, @message.moderation_scores)
    assert_not_nil @message.moderated_at
  end

  test "skips messages with blank content" do
    @message.update!(content: "")

    RubyLLM.stub(:moderate, ->(_) { raise "Should not be called" }) do
      ModerateMessageJob.perform_now(@message)
    end

    assert_nil @message.reload.moderated_at
  end

  test "skips already moderated messages" do
    @message.update!(moderated_at: 1.hour.ago)

    RubyLLM.stub(:moderate, ->(_) { raise "Should not be called" }) do
      ModerateMessageJob.perform_now(@message)
    end
  end
end
```

## Edge Cases and Error Handling

1. **Empty content**: Skip moderation for messages with blank content (tool calls, system messages)
2. **Rate limits**: Exponential backoff with up to 5 retries
3. **API errors**: 3 retries with 5-second wait
4. **Deleted messages**: Job discarded via `discard_on ActiveRecord::RecordNotFound`
5. **Already moderated**: Skip if `moderated_at` is present (idempotency)
6. **Missing API key**: `RubyLLM::ConfigurationError` will cause job failure (expected in dev without key)
7. **Nil scores**: Frontend handles nil/empty scores gracefully via `scores || {}`
8. **Threshold boundary**: `>= 0.5` includes exactly 50% - clear semantic meaning

## External Dependencies

- **RubyLLM** (existing): Moderation API via `RubyLLM.moderate(text)`
- **OpenAI API**: Requires `OPENAI_API_KEY` environment variable (already configured)

No new gems or npm packages required.

## Performance Considerations

1. **Asynchronous processing**: All moderation runs in background jobs, no impact on message send latency
2. **Minimal storage**: Only 2 columns, no redundant data
3. **Efficient serialization**: `moderation_severity` only included in JSON when scores present
4. **Real-time updates**: Uses existing Turbo Streams infrastructure

## Files to Create/Modify

### New Files
- `db/migrate/XXXXXX_add_moderation_to_messages.rb`
- `app/jobs/moderate_message_job.rb`
- `app/frontend/lib/components/chat/ModerationIndicator.svelte`
- `test/jobs/moderate_message_job_test.rb`

### Modified Files
- `app/models/message.rb` - Add constant, methods, callback, json_attributes
- `app/jobs/concerns/streams_ai_response.rb` - Queue moderation in finalize_message!
- `app/frontend/pages/chats/show.svelte` - Add ModerationIndicator to message bubbles
- `test/models/message_test.rb` - Add moderation tests

## Implementation Checklist

- [ ] Phase 1: Create database migration
- [ ] Phase 2: Create ModerateMessageJob
- [ ] Phase 3: Add moderation methods to Message model
- [ ] Phase 4: Update finalize_message! in StreamsAiResponse concern
- [ ] Phase 5: Create ModerationIndicator Svelte component
- [ ] Phase 6: Add ModerationIndicator to chat show page
- [ ] Phase 7: Write model tests
- [ ] Phase 8: Write job tests
- [ ] Run full test suite
- [ ] Manual testing in development
