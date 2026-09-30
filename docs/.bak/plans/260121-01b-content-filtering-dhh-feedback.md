# DHH Review: Content Moderation Display v2

**Reviewed**: 2026-01-21
**Spec Version**: v2 (260121-01b)
**Verdict**: Nearly Rails-worthy. A few refinements needed.

---

## Overall Assessment

This iteration is significantly tighter than before. The reduction to two database columns and derived `moderation_flagged?` demonstrates good instincts. The architecture diagram is clear, the job is idempotent, and the code follows Rails conventions reasonably well.

However, there are still areas where the code is working harder than necessary. The Svelte component carries more cognitive weight than it should, and the Ruby model methods could be more expressive. The testing approach is solid but could be more declarative.

This is good work that needs polish, not a rewrite.

---

## Critical Issues

None. The architecture is sound.

---

## Improvements Needed

### 1. The severity method has a logic bug

The table in Phase 7 is confusing ("0.5 < max score < 0.5" makes no sense), and the `moderation_severity` method returns `:low` for scores that are already above the threshold. Looking at the code:

```ruby
case max_score
when 0.8..1.0 then :high
when 0.5...0.8 then :medium
else :low
end
```

The `else :low` branch catches 0.5 exactly and anything below. But `moderation_severity` is only called when `moderation_flagged?` returns true, which requires a score > 0.5. So the only way to hit `:low` is with a score of exactly 0.501-0.499... which rounds to 0.5. This is edge-case noise.

**Fix**: Simplify. If the threshold is 0.5, then 0.5-0.8 is medium, 0.8+ is high. There is no "low" severity for flagged content.

```ruby
def moderation_severity
  return nil unless moderation_flagged?

  max_score = moderation_scores.values.max.to_f
  max_score >= 0.8 ? :high : :medium
end
```

This also lets you drop one colour from the frontend. Fewer states, less code.

### 2. The Svelte component has too many responsibilities

The `ModerationIndicator` component does four things: renders a button, manages drawer state, formats category names, and determines score colours. That is three too many.

**Current pain points**:
- `sortedCategories()` is a function that should be a `$derived`
- `formatCategoryName` and `getScoreColor` are utility functions polluting the component
- The component renders both the trigger AND the drawer content

**Refactored approach**:

```svelte
<script>
  import { WarningCircle } from 'phosphor-svelte';
  import * as Drawer from '$lib/components/shadcn/drawer/index.js';

  let { severity = null, scores = {} } = $props();
  let open = $state(false);

  const severityColor = $derived(
    severity === 'high' ? 'text-red-500' : 'text-orange-500'
  );

  const sortedScores = $derived(
    Object.entries(scores || {})
      .filter(([, score]) => score > 0.01)
      .sort(([, a], [, b]) => b - a)
  );
</script>

{#if severity}
  <button onclick={() => open = true} class="p-1 rounded-full hover:bg-muted {severityColor}">
    <WarningCircle size={18} weight="fill" />
  </button>

  <Drawer.Root bind:open direction="bottom">
    <Drawer.Content class="max-h-[60vh]">
      <Drawer.Header>
        <Drawer.Title class="flex items-center gap-2">
          <WarningCircle size={20} weight="fill" class={severityColor} />
          Content Moderation
        </Drawer.Title>
      </Drawer.Header>

      <div class="p-4 space-y-3 overflow-y-auto">
        {#each sortedScores as [category, score]}
          <ModerationCategory {category} {score} />
        {/each}
        <p class="text-xs text-muted-foreground mt-4 pt-4 border-t">
          Scores indicate likelihood of content matching each category.
        </p>
      </div>
    </Drawer.Content>
  </Drawer.Root>
{/if}
```

Create a separate `ModerationCategory.svelte` for the score bars. This keeps the main component focused on the interaction pattern.

Also note: the `flagged` prop is redundant. If `severity` is present, the content is flagged. Remove it.

### 3. The model constant should match its usage

```ruby
MODERATION_FLAG_THRESHOLD = 0.5
```

But then:
```ruby
moderation_scores.values.any? { |score| score.to_f > MODERATION_FLAG_THRESHOLD }
```

This flags content at 0.501 but not 0.500. That is probably fine, but be explicit. Either use `>=` or name the constant `MODERATION_FLAG_THRESHOLD_EXCLUSIVE`. The current code is technically correct but requires the reader to reason about floating point comparisons.

I would use `>=` because "above 50% confidence" includes 50%:

```ruby
def moderation_flagged?
  return false unless moderation_scores.present?
  moderation_scores.values.any? { |score| score.to_f >= MODERATION_FLAG_THRESHOLD }
end
```

### 4. The job should use find_by with guard clause

Current:
```ruby
def perform(message)
  return if message.content.blank?
  return if message.moderated_at.present?
```

The `discard_on ActiveRecord::RecordNotFound` only catches the case where the job receives an ID for a deleted record. But you are passing the message object, not an ID. ActiveJob serializes and deserializes the record, so `RecordNotFound` will be raised on deserialization if the record is gone.

However, the explicit guards for blank content and already-moderated messages read better as a single conditional:

```ruby
def perform(message)
  return unless message.content.present? && message.moderated_at.nil?

  result = RubyLLM.moderate(message.content)
  message.update!(moderation_scores: result.category_scores, moderated_at: Time.current)
end
```

This reads as: "Return unless the message has content and hasn't been moderated."

### 5. The frontend threshold is duplicated

The Svelte component has:
```javascript
{@const isFlagged = score > 0.5}
```

This duplicates `MODERATION_FLAG_THRESHOLD` from the Ruby model. If you change the threshold, you must remember to update both places.

**Fix**: Pass the threshold from the backend, or accept that the frontend only displays what the backend already computed. Since you already pass `severity`, the frontend does not need to re-determine what is flagged. The backend has already made that decision.

Remove the `isFlagged` logic from the frontend. Instead, the backend should only pass categories that exceed the threshold, or pass a `flagged_categories` array.

Simpler: just show all categories sorted by score. The user can see which ones are high. No threshold logic needed in the frontend.

---

## What Works Well

1. **Two columns instead of four** - Derived state is the right call
2. **Idempotent job design** - The `moderated_at` check prevents double-processing
3. **Using `after_commit`** - Correctly ensures the message is persisted before enqueueing
4. **Real-time updates via existing Broadcastable** - No new infrastructure needed
5. **Test coverage** - Good edge case coverage in the unit tests
6. **Architecture diagram** - Clear and helpful

---

## Refactored Version

### Message Model Additions

```ruby
class Message < ApplicationRecord
  MODERATION_THRESHOLD = 0.5

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

### Job

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

### Simplified Svelte Component

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

**Changes from original**:
- Removed `flagged` prop (derived from `severity`)
- Removed `severityLabels` (not necessary in drawer header)
- Removed `getScoreColor` function (inlined in template)
- Changed `sortedCategories()` function to `sortedScores` derived value
- Removed redundant warning icon per category row
- Simplified percentage display (`.toFixed(0)` instead of `.toFixed(1)`)
- Two severities instead of three

---

## Summary of Changes Needed

| Item | Effort | Impact |
|------|--------|--------|
| Fix severity to two levels (medium/high) | Low | Simplifies frontend |
| Change threshold comparison to `>=` | Trivial | Correctness |
| Remove `flagged` prop from Svelte | Low | DRY |
| Convert `sortedCategories()` to `$derived` | Low | Idiomatic Svelte 5 |
| Simplify job guard clause | Trivial | Readability |

Total effort: One focused hour. The spec is close. These are refinements, not rewrites.
