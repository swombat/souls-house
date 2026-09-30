# Implementation Plan: Content Moderation Display

**Date**: 2026-01-21
**Status**: Draft
**Feature**: Visual moderation indicators for chat messages

## Executive Summary

Add content moderation to all messages (user and assistant) using RubyLLM's moderation API. The system displays a warning icon next to flagged messages with severity-based colouring. Tapping the icon reveals a bottom sheet showing all flagged categories with their scores.

This is an informational feature, not a blocking mechanism. Some AI providers (like Grok) produce content that may trigger moderation flags, and users benefit from visibility into these scores.

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
    add_column :messages, :moderation_flagged, :boolean, default: false, null: false
    add_column :messages, :moderation_categories, :jsonb, default: {}
    add_column :messages, :moderation_scores, :jsonb, default: {}
    add_column :messages, :moderated_at, :datetime

    add_index :messages, :moderation_flagged, where: "moderation_flagged = true"
  end
end
```

**Design Notes**:
- `moderation_flagged`: Quick boolean check for UI rendering
- `moderation_categories`: Hash of `{ "sexual" => true, "hate" => false, ... }` - the boolean flags
- `moderation_scores`: Hash of `{ "sexual" => 0.01, "hate" => 0.85, ... }` - the confidence scores
- `moderated_at`: Timestamp for tracking when moderation occurred
- Partial index on flagged messages for efficient queries

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
      moderation_flagged: result.flagged?,
      moderation_categories: result.categories,
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

### Phase 3: Model Changes

- [ ] Update Message model with moderation methods and callbacks

**File**: `app/models/message.rb` (additions)

```ruby
class Message < ApplicationRecord
  # ... existing code ...

  # Add to json_attributes for frontend serialization
  json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                  :completed, :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :content_html, :tools_used, :tool_status,
                  :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                  :editable, :deletable,
                  :moderation_flagged, :moderation_severity, :moderation_details

  # Queue moderation after user messages are created
  after_commit :queue_moderation, on: :create, if: :should_moderate_on_create?

  # Moderation severity level for UI colour coding
  # Returns: :low, :medium, :high, or nil if not flagged
  def moderation_severity
    return nil unless moderation_flagged?

    max_score = moderation_scores.values.compact.max || 0

    case max_score
    when 0.8..1.0 then :high
    when 0.5...0.8 then :medium
    else :low
    end
  end

  # Formatted moderation details for bottom sheet display
  def moderation_details
    return nil unless moderation_flagged?

    moderation_scores
      .select { |category, score| score > 0.01 }
      .sort_by { |_, score| -score }
      .map do |category, score|
        {
          category: format_category_name(category),
          score: score,
          flagged: moderation_categories[category] == true
        }
      end
  end

  private

  def should_moderate_on_create?
    role == "user" && content.present?
  end

  def queue_moderation
    ModerateMessageJob.perform_later(self)
  end

  def format_category_name(category)
    category.to_s.gsub("/", " / ").titleize
  end
end
```

**Design Notes**:
- User messages queue moderation on create (after_commit ensures transaction committed)
- Assistant messages are moderated via `finalize_message!` in the job concern
- `moderation_severity` provides a simple enum for UI colour mapping
- `moderation_details` formats the data for the bottom sheet

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

### Phase 5: Frontend Components

- [ ] Create ModerationIndicator component

**File**: `app/frontend/lib/components/chat/ModerationIndicator.svelte`

```svelte
<script>
  import { WarningCircle } from 'phosphor-svelte';
  import * as Drawer from '$lib/components/shadcn/drawer/index.js';
  import { Progress } from '$lib/components/shadcn/progress/index.js';

  let {
    flagged = false,
    severity = null,
    details = []
  } = $props();

  let drawerOpen = $state(false);

  const severityColors = {
    low: 'text-yellow-500',
    medium: 'text-orange-500',
    high: 'text-red-500'
  };

  const severityBgColors = {
    low: 'bg-yellow-50 dark:bg-yellow-950/30',
    medium: 'bg-orange-50 dark:bg-orange-950/30',
    high: 'bg-red-50 dark:bg-red-950/30'
  };

  const severityLabels = {
    low: 'Low concern',
    medium: 'Moderate concern',
    high: 'High concern'
  };

  function getScoreColor(score) {
    if (score >= 0.8) return 'bg-red-500';
    if (score >= 0.5) return 'bg-orange-500';
    if (score >= 0.2) return 'bg-yellow-500';
    return 'bg-gray-300';
  }
</script>

{#if flagged && severity}
  <button
    onclick={() => drawerOpen = true}
    class="p-1 rounded-full hover:bg-muted transition-colors {severityColors[severity]}"
    title="Content moderation warning - tap for details">
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
          {severityLabels[severity]} - This message has been flagged by the content moderation system.
        </Drawer.Description>
      </Drawer.Header>

      <div class="p-4 space-y-3 overflow-y-auto">
        {#each details as item}
          <div class="flex items-center gap-3 p-2 rounded {item.flagged ? severityBgColors[severity] : ''}">
            <div class="flex-1">
              <div class="flex items-center justify-between mb-1">
                <span class="text-sm font-medium">{item.category}</span>
                <span class="text-xs text-muted-foreground">{(item.score * 100).toFixed(1)}%</span>
              </div>
              <div class="h-2 bg-muted rounded-full overflow-hidden">
                <div
                  class="h-full transition-all {getScoreColor(item.score)}"
                  style="width: {item.score * 100}%">
                </div>
              </div>
            </div>
            {#if item.flagged}
              <WarningCircle size={16} weight="fill" class={severityColors[severity]} />
            {/if}
          </div>
        {/each}

        <p class="text-xs text-muted-foreground mt-4 pt-4 border-t">
          Content moderation is provided for informational purposes. Scores indicate the likelihood
          of content matching each category. This does not affect message delivery.
        </p>
      </div>
    </Drawer.Content>
  </Drawer.Root>
{/if}
```

- [ ] Update chat/show.svelte to include ModerationIndicator

**File**: `app/frontend/pages/chats/show.svelte` (modifications)

Add import at top:
```svelte
import ModerationIndicator from '$lib/components/chat/ModerationIndicator.svelte';
```

In the user message bubble section (around line 1258), add after the Card.Root closing tag:
```svelte
<Card.Root class="{getBubbleClass(message.author_colour)} w-fit">
  <!-- existing content -->
</Card.Root>
{#if message.moderation_flagged}
  <ModerationIndicator
    flagged={message.moderation_flagged}
    severity={message.moderation_severity}
    details={message.moderation_details || []} />
{/if}
```

In the assistant message bubble section (around line 1331), add after the Card.Root closing tag:
```svelte
</Card.Root>
{#if message.moderation_flagged}
  <div class="mt-1">
    <ModerationIndicator
      flagged={message.moderation_flagged}
      severity={message.moderation_severity}
      details={message.moderation_details || []} />
  </div>
{/if}
```

### Phase 6: Colour Scheme Reference

| Severity | Icon Colour | Background (light) | Background (dark) | Threshold |
|----------|-------------|-------------------|-------------------|-----------|
| Low | `text-yellow-500` | `bg-yellow-50` | `bg-yellow-950/30` | score < 0.5 |
| Medium | `text-orange-500` | `bg-orange-50` | `bg-orange-950/30` | 0.5 <= score < 0.8 |
| High | `text-red-500` | `bg-red-50` | `bg-red-950/30` | score >= 0.8 |

### Phase 7: Real-time Updates

The existing Broadcastable concern on Message will handle real-time updates automatically. When `ModerateMessageJob` calls `update!` on the message, the `broadcast_replace_to` callback will push the updated message (with moderation data) to the frontend via Turbo Streams.

No additional ActionCable configuration needed - the existing `broadcasts_to :chat` handles this.

## Testing Strategy

- [ ] Unit tests for Message model

**File**: `test/models/message_test.rb` (additions)

```ruby
class MessageTest < ActiveSupport::TestCase
  test "moderation_severity returns nil when not flagged" do
    message = messages(:one)
    message.moderation_flagged = false
    assert_nil message.moderation_severity
  end

  test "moderation_severity returns :high for scores >= 0.8" do
    message = messages(:one)
    message.moderation_flagged = true
    message.moderation_scores = { "hate" => 0.85, "violence" => 0.2 }
    assert_equal :high, message.moderation_severity
  end

  test "moderation_severity returns :medium for scores 0.5-0.8" do
    message = messages(:one)
    message.moderation_flagged = true
    message.moderation_scores = { "hate" => 0.65, "violence" => 0.2 }
    assert_equal :medium, message.moderation_severity
  end

  test "moderation_severity returns :low for scores < 0.5" do
    message = messages(:one)
    message.moderation_flagged = true
    message.moderation_scores = { "hate" => 0.3, "violence" => 0.2 }
    assert_equal :low, message.moderation_severity
  end

  test "moderation_details formats and sorts categories by score" do
    message = messages(:one)
    message.moderation_flagged = true
    message.moderation_categories = { "hate" => true, "violence" => false }
    message.moderation_scores = { "hate" => 0.85, "violence" => 0.3 }

    details = message.moderation_details
    assert_equal 2, details.length
    assert_equal "Hate", details.first[:category]
    assert_equal 0.85, details.first[:score]
    assert details.first[:flagged]
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
    @message.update!(content: "Test content", moderated_at: nil)
  end

  test "calls RubyLLM.moderate and updates message" do
    mock_result = OpenStruct.new(
      flagged?: true,
      categories: { "hate" => true, "violence" => false },
      category_scores: { "hate" => 0.85, "violence" => 0.1 }
    )

    RubyLLM.stub(:moderate, mock_result) do
      ModerateMessageJob.perform_now(@message)
    end

    @message.reload
    assert @message.moderation_flagged
    assert_equal({ "hate" => true, "violence" => false }, @message.moderation_categories)
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

  test "handles deleted messages gracefully" do
    message_id = @message.id
    @message.destroy!

    # Should not raise, job should be discarded
    assert_nothing_raised do
      ModerateMessageJob.perform_now(Message.find(message_id))
    end
  rescue ActiveRecord::RecordNotFound
    # Expected - job will be discarded
  end
end
```

- [ ] Integration test for full flow

**File**: `test/integration/content_moderation_test.rb`

```ruby
require "test_helper"

class ContentModerationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @account = accounts(:one)
    @chat = chats(:one)
    sign_in_as(@user)
  end

  test "user message gets moderated after creation" do
    mock_result = OpenStruct.new(
      flagged?: true,
      categories: { "harassment" => true },
      category_scores: { "harassment" => 0.75 }
    )

    RubyLLM.stub(:moderate, mock_result) do
      post account_chat_messages_path(@account, @chat), params: {
        message: { content: "Test message" }
      }

      perform_enqueued_jobs
    end

    message = @chat.messages.last
    assert message.moderation_flagged
    assert_equal :medium, message.moderation_severity
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

## External Dependencies

- **RubyLLM** (existing): Moderation API via `RubyLLM.moderate(text)`
- **OpenAI API**: Requires `OPENAI_API_KEY` environment variable (already configured for chat)

No new gems or npm packages required.

## Performance Considerations

1. **Asynchronous processing**: All moderation runs in background jobs, no impact on message send latency
2. **Efficient queries**: Partial index on `moderation_flagged = true` for any future admin queries
3. **Minimal payload**: Only flagged messages include `moderation_details` in JSON (nil otherwise)
4. **Debounced updates**: Real-time updates use existing Turbo Streams infrastructure

## Migration Notes

- Existing messages will have `moderation_flagged: false` and empty moderation data
- No backfill job needed (moderation is informational, not blocking)
- Optional: Create a rake task to backfill moderation for historical messages if desired

## Rollback Plan

1. Remove frontend components (no breaking change, just hidden UI)
2. Remove job calls from model and concern
3. Keep database columns (no data loss, just unused)
4. Or run `rails db:migrate:down VERSION=XXXXXX` to remove columns

## Files to Create/Modify

### New Files
- `db/migrate/XXXXXX_add_moderation_to_messages.rb`
- `app/jobs/moderate_message_job.rb`
- `app/frontend/lib/components/chat/ModerationIndicator.svelte`
- `test/jobs/moderate_message_job_test.rb`
- `test/integration/content_moderation_test.rb`

### Modified Files
- `app/models/message.rb` - Add moderation methods, callback, json_attributes
- `app/jobs/concerns/streams_ai_response.rb` - Queue moderation in finalize_message!
- `app/frontend/pages/chats/show.svelte` - Add ModerationIndicator to message bubbles
- `test/models/message_test.rb` - Add moderation tests
