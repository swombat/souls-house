# Implementation Plan: Content Moderation Display (v2)

**Date**: 2026-01-21
**Status**: Draft
**Feature**: Visual moderation indicators for chat messages
**Revision**: Incorporates DHH feedback while preserving user requirements

## Executive Summary

Add content moderation to all messages (user and assistant) using RubyLLM's moderation API. The system displays a warning icon next to flagged messages with severity-based colouring. Tapping the icon reveals a bottom sheet showing all flagged categories with their scores.

This is an informational feature, not a blocking mechanism.

## Changes from v1

Applied DHH's feedback:
- **2 database columns** instead of 4 (only `moderation_scores` and `moderated_at`)
- **Derived `moderation_flagged?`** method from scores using threshold constant
- **Simplified job** stores only scores, not redundant categories/flagged boolean
- **Removed `moderation_details`** method - frontend reads scores directly

Preserved user requirements:
- **Severity-based colour coding** (yellow/orange/red based on max score)
- **Bottom sheet drawer** with category details (not a popover)
- **Single warning icon** per message regardless of flagged category count

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
    return if message.content.blank?
    return if message.moderated_at.present?

    result = RubyLLM.moderate(message.content)

    message.update!(
      moderation_scores: result.category_scores,
      moderated_at: Time.current
    )
  end
end
```

**Design Notes**:
- Skip messages with no content (empty assistant messages during tool calls)
- Skip already-moderated messages (idempotency)
- Retry on rate limits with backoff
- Discard job if message deleted before processing
- Only store scores - flagged state is derived

### Phase 3: Model Changes

- [ ] Update Message model with moderation methods and callbacks

**File**: `app/models/message.rb` (additions)

```ruby
class Message < ApplicationRecord
  MODERATION_FLAG_THRESHOLD = 0.5

  json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                  :completed, :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :content_html, :tools_used, :tool_status,
                  :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                  :editable, :deletable,
                  :moderation_flagged, :moderation_severity, :moderation_scores

  after_commit :queue_moderation, on: :create, if: :should_moderate_on_create?

  def moderation_flagged?
    return false unless moderation_scores.present?
    moderation_scores.values.any? { |score| score.to_f > MODERATION_FLAG_THRESHOLD }
  end

  alias_method :moderation_flagged, :moderation_flagged?

  def moderation_severity
    return nil unless moderation_flagged?

    max_score = moderation_scores.values.compact.max || 0

    case max_score
    when 0.8..1.0 then :high
    when 0.5...0.8 then :medium
    else :low
    end
  end

  private

  def should_moderate_on_create?
    role == "user" && content.present?
  end

  def queue_moderation
    ModerateMessageJob.perform_later(self)
  end
end
```

**Design Notes**:
- `MODERATION_FLAG_THRESHOLD` centralizes the threshold (0.5) in one place
- `moderation_flagged?` derives the boolean from scores - no redundant database column
- `moderation_severity` returns :low/:medium/:high for UI colour mapping
- `moderation_scores` is passed directly to frontend - no `moderation_details` transformation
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

  let {
    flagged = false,
    severity = null,
    scores = {}
  } = $props();

  let drawerOpen = $state(false);

  const severityColors = {
    low: 'text-yellow-500',
    medium: 'text-orange-500',
    high: 'text-red-500'
  };

  const severityLabels = {
    low: 'Low concern',
    medium: 'Moderate concern',
    high: 'High concern'
  };

  function formatCategoryName(category) {
    return category.replace(/[/_-]/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
  }

  function getScoreColor(score) {
    if (score >= 0.8) return 'bg-red-500';
    if (score >= 0.5) return 'bg-orange-500';
    if (score >= 0.2) return 'bg-yellow-500';
    return 'bg-gray-300';
  }

  function sortedCategories() {
    if (!scores) return [];
    return Object.entries(scores)
      .filter(([_, score]) => score > 0.01)
      .sort(([, a], [, b]) => b - a);
  }
</script>

{#if flagged && severity}
  <button
    onclick={() => drawerOpen = true}
    class="p-1 rounded-full hover:bg-muted transition-colors {severityColors[severity]}"
    title="Content moderation warning">
    <WarningCircle size={18} weight="fill" />
  </button>

  <Drawer.Root bind:open={drawerOpen} direction="bottom">
    <Drawer.Content class="max-h-[60vh]">
      <Drawer.Header>
        <Drawer.Title class="flex items-center gap-2">
          <WarningCircle size={20} weight="fill" class={severityColors[severity]} />
          Content Moderation
        </Drawer.Title>
        <Drawer.Description>
          {severityLabels[severity]} - This message was flagged by automated moderation.
        </Drawer.Description>
      </Drawer.Header>

      <div class="p-4 space-y-3 overflow-y-auto">
        {#each sortedCategories() as [category, score]}
          {@const isFlagged = score > 0.5}
          <div class="flex items-center gap-3 p-2 rounded {isFlagged ? 'bg-muted' : ''}">
            <div class="flex-1">
              <div class="flex items-center justify-between mb-1">
                <span class="text-sm font-medium">{formatCategoryName(category)}</span>
                <span class="text-xs text-muted-foreground">{(score * 100).toFixed(1)}%</span>
              </div>
              <div class="h-2 bg-muted rounded-full overflow-hidden">
                <div
                  class="h-full transition-all {getScoreColor(score)}"
                  style="width: {score * 100}%">
                </div>
              </div>
            </div>
            {#if isFlagged}
              <WarningCircle size={16} weight="fill" class={severityColors[severity]} />
            {/if}
          </div>
        {/each}

        <p class="text-xs text-muted-foreground mt-4 pt-4 border-t">
          Content moderation is informational only. Scores indicate the likelihood
          of content matching each category. This does not affect message delivery.
        </p>
      </div>
    </Drawer.Content>
  </Drawer.Root>
{/if}
```

**Design Notes**:
- Receives `scores` directly from model - no backend transformation
- `sortedCategories()` handles filtering and sorting in frontend
- Uses `score > 0.5` to determine if a category is flagged (matches `MODERATION_FLAG_THRESHOLD`)
- Bottom sheet drawer per user requirement (not popover)
- Severity-based colours per user requirement

### Phase 6: Update Chat Show Page

- [ ] Add ModerationIndicator to user message bubbles

**File**: `app/frontend/pages/chats/show.svelte`

Add import at top:
```svelte
import ModerationIndicator from '$lib/components/chat/ModerationIndicator.svelte';
```

In the user message section (around line 1260, after the timestamp div):
```svelte
<div class="text-xs text-muted-foreground text-right mt-1 flex items-center justify-end gap-2">
  {#if message.moderation_flagged}
    <ModerationIndicator
      flagged={message.moderation_flagged}
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

In the assistant message section (around line 1332, in the timestamp div):
```svelte
<div class="text-xs text-muted-foreground mt-1 flex items-center gap-2">
  {#if message.moderation_flagged}
    <ModerationIndicator
      flagged={message.moderation_flagged}
      severity={message.moderation_severity}
      scores={message.moderation_scores} />
  {/if}
  {#if chat?.manual_responses && message.author_name}
    <span class="mr-1">{message.author_name} ·</span>
  {/if}
  <!-- rest of existing content -->
</div>
```

### Phase 7: Colour Scheme Reference

| Severity | Icon Colour | Threshold |
|----------|-------------|-----------|
| Low | `text-yellow-500` | 0.5 < max score < 0.5 (flagged but below medium) |
| Medium | `text-orange-500` | 0.5 <= max score < 0.8 |
| High | `text-red-500` | max score >= 0.8 |

Note: The "Low" severity case handles edge cases where a category is flagged at exactly the threshold.

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

  test "moderation_flagged? returns false when no scores exceed threshold" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.3, "violence" => 0.2 }
    assert_not message.moderation_flagged?
  end

  test "moderation_flagged? returns true when any score exceeds threshold" do
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

  test "moderation_severity returns :low for flagged messages with scores < 0.5 but above threshold" do
    message = messages(:one)
    message.moderation_scores = { "hate" => 0.51, "violence" => 0.2 }
    assert_equal :low, message.moderation_severity
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
7. **Nil scores**: Frontend handles nil/empty scores gracefully

## External Dependencies

- **RubyLLM** (existing): Moderation API via `RubyLLM.moderate(text)`
- **OpenAI API**: Requires `OPENAI_API_KEY` environment variable (already configured)

No new gems or npm packages required.

## Performance Considerations

1. **Asynchronous processing**: All moderation runs in background jobs, no impact on message send latency
2. **Minimal storage**: Only 2 columns instead of 4, no redundant data
3. **Efficient serialization**: `moderation_scores` only included in JSON when present
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
