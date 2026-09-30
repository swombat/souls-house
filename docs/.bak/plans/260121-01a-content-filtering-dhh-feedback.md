# DHH-Style Review: Content Moderation Display Spec

**Reviewer**: David Heinemeier Hansson (simulated)
**Date**: 2026-01-21
**Verdict**: Mostly good, but needs trimming

---

## Overall Assessment

This spec is 80% of the way there. It follows the fundamental Rails philosophy: background jobs for async work, fat models for business logic, real-time updates through existing ActionCable infrastructure. The approach of using `after_commit` callbacks and leveraging the existing `broadcasts_to :chat` pattern is exactly right.

However, there is unnecessary complexity in the frontend component and some redundant data modelling that smells of over-engineering. The spec also commits a cardinal sin: it proposes three severity levels with thresholds that feel arbitrary. When in doubt, simplify.

---

## Critical Issues

### 1. Three Columns for Two Concepts

The migration creates four columns when two would suffice:

```ruby
add_column :messages, :moderation_flagged, :boolean, default: false, null: false
add_column :messages, :moderation_categories, :jsonb, default: {}
add_column :messages, :moderation_scores, :jsonb, default: {}
add_column :messages, :moderated_at, :datetime
```

The `moderation_categories` column is redundant. You already have `moderation_scores`. A category is flagged when its score exceeds a threshold. You do not need to store both the boolean and the score.

**Simplify to:**

```ruby
add_column :messages, :moderation_scores, :jsonb
add_column :messages, :moderated_at, :datetime
```

`moderation_flagged` can be a method:

```ruby
def moderation_flagged?
  moderation_scores.present? && moderation_scores.values.any? { |v| v > 0.5 }
end
```

The partial index is premature optimization. You have no evidence you will need to query flagged messages at scale. Add it when profiling demands it.

### 2. Severity Levels Are Over-Engineering

Low, medium, high severity with colour coding? This is a content moderation indicator, not a threat assessment dashboard. The user needs to know one thing: "this message was flagged."

**Simplify to: flagged or not flagged.** One colour. One icon. One state.

If you must have severity, two levels maximum: "flagged" and "severely flagged". But I would argue even that is too much for an "informational, not blocking" feature.

The thresholds (0.5, 0.8) are arbitrary. You will spend time debating them. Users will not care about the distinction.

### 3. The Svelte Component Is Over-Built

The `ModerationIndicator.svelte` component is 90 lines of code for what should be 20.

You have:
- Three severity colours
- Three severity backgrounds
- Three severity labels
- A progress bar for each category
- A bottom drawer with detailed breakdown

For an informational feature that most users will never interact with, this is excessive. The drawer with per-category scores is feature creep. Who is this for? The user who wants to know their message scored 0.85 on "hate" versus 0.65? Nobody.

**Simplify to:**

```svelte
<script>
  import { WarningCircle } from 'phosphor-svelte';
  import * as Popover from '$lib/components/shadcn/popover/index.js';

  let { flagged = false } = $props();
</script>

{#if flagged}
  <Popover.Root>
    <Popover.Trigger>
      <button class="p-1 text-amber-500" title="Content flagged by moderation">
        <WarningCircle size={16} weight="fill" />
      </button>
    </Popover.Trigger>
    <Popover.Content class="text-sm">
      This message was flagged by automated content moderation.
    </Popover.Content>
  </Popover.Root>
{/if}
```

Twenty lines. A simple popover. Done. The user knows it was flagged. That is all they need.

---

## Improvements Needed

### 1. Drop `moderation_details` Method

This method formats data for a UI that should not exist:

```ruby
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
```

This is formatting presentation data in a model. If you truly need category details, the frontend can iterate over `moderation_scores` directly. Do not create bespoke data structures in the model for one UI component.

### 2. Simplify `json_attributes`

Instead of adding three attributes:

```ruby
:moderation_flagged, :moderation_severity, :moderation_details
```

Add one:

```ruby
:moderation_flagged
```

That is it. The frontend gets a boolean. The icon shows or it does not.

### 3. The Job Is Good, But Tighten It Up

The job is nearly correct. However:

```ruby
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
```

With the simplified schema:

```ruby
def perform(message)
  return if message.content.blank?
  return if message.moderated_at.present?

  result = RubyLLM.moderate(message.content)

  message.update!(
    moderation_scores: result.category_scores,
    moderated_at: Time.current
  )
end
```

Let the model method `moderation_flagged?` derive the boolean from scores.

### 4. Move the Threshold to a Constant

If you need a threshold for "flagged":

```ruby
class Message < ApplicationRecord
  MODERATION_FLAG_THRESHOLD = 0.5

  def moderation_flagged?
    return false unless moderation_scores.present?
    moderation_scores.values.any? { |score| score.to_f > MODERATION_FLAG_THRESHOLD }
  end
end
```

Now the threshold is in one place, not scattered across frontend colour mappings.

---

## What Works Well

### 1. The Architecture Flow Is Correct

```
User Message Created -> after_commit -> ModerateMessageJob
AI Message Finalized -> finalize_message! -> enqueue job
ModerateMessageJob -> RubyLLM.moderate() -> update message
                   -> broadcast_replace_to (real-time update)
```

This is textbook Rails. Background jobs for external API calls. Callbacks for enqueueing. Real-time updates through existing infrastructure. No new channels, no new broadcast patterns. This is how it should be done.

### 2. Using `after_commit` Not `after_create`

Correct. The transaction must be committed before enqueueing the job, otherwise the job might try to find a record that does not exist yet. This is a common mistake that the spec avoids.

### 3. Leveraging Existing `broadcasts_to :chat`

The spec correctly notes that no new ActionCable configuration is needed. The existing `broadcasts_to :chat` will handle the update. This is restraint. This is Rails.

### 4. The Guard Clauses in the Job

```ruby
return if message.content.blank?
return if message.moderated_at.present?
```

Idempotency. Defensive coding. Good.

### 5. The Retry Strategy

```ruby
retry_on RubyLLM::RateLimitError, wait: :polynomially_longer, attempts: 5
retry_on RubyLLM::Error, wait: 5.seconds, attempts: 3
discard_on ActiveRecord::RecordNotFound
```

Sensible defaults. Not trying to be too clever.

---

## Refactored Version

### Migration

```ruby
class AddModerationToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :moderation_scores, :jsonb
    add_column :messages, :moderated_at, :datetime
  end
end
```

### Model Addition

```ruby
class Message < ApplicationRecord
  MODERATION_FLAG_THRESHOLD = 0.5

  json_attributes :role, :content, # ... existing attributes ...,
                  :moderation_flagged

  after_commit :queue_moderation, on: :create, if: :should_moderate_on_create?

  def moderation_flagged?
    return false unless moderation_scores.present?
    moderation_scores.values.any? { |score| score.to_f > MODERATION_FLAG_THRESHOLD }
  end

  alias_method :moderation_flagged, :moderation_flagged?

  private

  def should_moderate_on_create?
    role == "user" && content.present?
  end

  def queue_moderation
    ModerateMessageJob.perform_later(self)
  end
end
```

### Job

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

### Svelte Component

```svelte
<script>
  import { WarningCircle } from 'phosphor-svelte';
  import * as Popover from '$lib/components/shadcn/popover/index.js';

  let { flagged = false } = $props();
</script>

{#if flagged}
  <Popover.Root>
    <Popover.Trigger>
      <button
        class="p-1 text-amber-500 hover:text-amber-600 transition-colors"
        title="Content moderation warning">
        <WarningCircle size={16} weight="fill" />
      </button>
    </Popover.Trigger>
    <Popover.Content class="text-sm max-w-64">
      <p>This message was flagged by automated content moderation.</p>
      <p class="text-xs text-muted-foreground mt-1">This is informational only and does not affect delivery.</p>
    </Popover.Content>
  </Popover.Root>
{/if}
```

### Usage in show.svelte

```svelte
import ModerationIndicator from '$lib/components/chat/ModerationIndicator.svelte';

<!-- In message bubble -->
{#if message.moderation_flagged}
  <ModerationIndicator flagged={message.moderation_flagged} />
{/if}
```

---

## Testing Notes

The proposed tests are reasonable but test too many implementation details. Focus on:

1. `moderation_flagged?` returns true when any score exceeds threshold
2. `moderation_flagged?` returns false when no scores exceed threshold
3. User messages enqueue moderation job on create
4. Assistant messages do not enqueue on create
5. Job updates scores and timestamp
6. Job skips already-moderated messages

You do not need separate tests for "high", "medium", and "low" severity because those concepts should not exist.

---

## Final Words

This is a solid spec that got carried away with UI complexity. The backend architecture is correct. The frontend is over-built for an informational feature.

Remember: the best code is code you do not write. You can always add the detailed category breakdown later if users actually ask for it. They will not.

Ship the simple version. A yellow warning icon. A popover that says "flagged." Done.

*"Perfection is achieved not when there is nothing more to add, but when there is nothing left to take away."* - Antoine de Saint-Exupery (and every good Rails developer)
