# DHH Review: Agent Voices Implementation Spec

**Date**: 2026-02-22
**Reviewing**: `/docs/plans/260222-01a-agent-voices.md`

---

## Overall Assessment

This is a well-structured, confidently scoped implementation plan. It flows *with* the existing codebase rather than against it -- mirroring established patterns (the STT lib, the nested `Messages::` controllers, the `json_attributes` serialization), keeping the touch surface small (ten files), and resisting the temptation to over-abstract. The architecture diagram at the top tells the whole story in twelve lines -- that is a sign of the right level of complexity. There are a handful of places where the spec introduces unnecessary friction or departs from patterns already established in the codebase, but nothing structural is wrong. This is close to being ready to build.

---

## Critical Issues

### 1. The controller authorization is inconsistent with the existing pattern

The spec's `VoicesController` rolls its own authorization:

```ruby
def set_message_and_chat
  @message = Message.find(params[:message_id])
  @chat = if Current.user.site_admin
    Chat.find(@message.chat_id)
  else
    Chat.where(id: @message.chat_id, account_id: Current.user.account_ids).first!
  end
end
```

This is a direct copy of `HallucinationFixesController#set_message_and_chat`. When two controllers share identical private methods, that is a textbook DRY violation. But more importantly, `RetriesController` does it *differently* -- it uses `current_account.chats.find(@message.chat_id)`, which is simpler and more idiomatic (it leverages the `AccountScoping` concern that already provides `current_account`).

**The problem**: The `Messages::` controllers are not nested under accounts in the routes (they are top-level `resources :messages`), so `current_account` may not be set from `params[:account_id]`. The `HallucinationFixesController` pattern was written to work around this. But `RetriesController` just uses `current_account` anyway and it works -- `AccountScoping` falls back to `Current.user.default_account`.

**Recommendation**: If the two approaches both work, standardize on the simpler one. If they do not, the divergence is a bug that should be fixed before being copied a third time. Either way, this shared authorization logic should be extracted into a concern or a shared base class:

```ruby
# app/controllers/messages/base_controller.rb
class Messages::BaseController < ApplicationController
  require_feature_enabled :chats
  before_action :set_message_and_chat

  private

  def set_message_and_chat
    @message = Message.find(params[:message_id])
    @chat = current_account.chats.find(@message.chat_id)
  end
end
```

Then `VoicesController`, `RetriesController`, and `HallucinationFixesController` all inherit from it.

### 2. The `content_for_speech` method is too long for a model

The `content_for_speech` method (Step 4) is 40 lines of regex transformations. The spec correctly identifies this as "a transformation of the message's own content -- classic model territory." True, it *belongs* on the model. But a 40-line chain of `gsub!` calls is not a model method -- it is a text processing pipeline that happens to live on a model.

The Message model (`/app/models/message.rb`) is already 614 lines. Adding another 40 lines of regex logic pushes it further toward bloat.

**Recommendation**: Extract a plain old Ruby object:

```ruby
# app/models/message/speech_text.rb
class Message::SpeechText
  MAX_LENGTH = 5_000

  def initialize(content)
    @text = content.to_s.dup
  end

  def to_s
    strip_code_blocks
    strip_inline_code
    strip_images
    strip_links
    strip_urls
    strip_stage_directions
    strip_markdown_formatting
    collapse_whitespace
    @text.strip.truncate(MAX_LENGTH)
  end

  private

  def strip_code_blocks
    @text.gsub!(/```[\s\S]*?```/, "I've included a code block here.")
  end

  def strip_inline_code
    @text.gsub!(/`([^`]+)`/) { $1 }
  end

  # ... each transformation as a named method
end
```

Then the model method becomes a one-liner:

```ruby
def content_for_speech
  Message::SpeechText.new(content).to_s
end
```

This is not a "service object" -- it is a value object that encapsulates text transformation. It is independently testable, keeps the model clean, and each regex gets a name that explains what it does instead of a comment.

---

## Improvements Needed

### 3. The requirements say no background job -- the spec adds one anyway

The requirements document (`/docs/requirements/260222-01-agent-voices.md`) explicitly states under "What NOT to build":

> No pre-rendering / background job to render all messages.

Then under "Clarifications" it contradicts itself:

> The voice endpoint should kick off a background job rather than making the user wait synchronously.

The spec follows the clarification, which is the right call. The async pattern is clearly better UX. But the requirements document should be cleaned up so the contradiction does not confuse future readers. This is not a code issue -- it is a spec hygiene issue.

### 4. The frontend `requestVoice` function maps over the array three times for error handling

Look at the error handling in Step 10:

```javascript
// On error -- clear loading
recentMessages = recentMessages.map((m) =>
  m.id === messageId ? { ...m, _voice_loading: false } : m
);
```

This exact `map` call appears *three times* -- once in the else branch, once in the catch, and once in the success path (with different fields). The function is 35 lines of nearly identical array mapping.

**Recommendation**: Extract a helper that updates a single message in the array:

```javascript
function updateMessage(messageId, patch) {
  recentMessages = recentMessages.map((m) =>
    m.id === messageId ? { ...m, ...patch } : m
  );
}

async function requestVoice(messageId) {
  updateMessage(messageId, { _voice_loading: true });

  try {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || '';
    const response = await fetch(messageVoicePath(messageId), {
      method: 'POST',
      headers: { 'X-CSRF-Token': csrfToken, Accept: 'application/json' },
    });

    if (response.status === 200) {
      const { voice_audio_url } = await response.json();
      updateMessage(messageId, { voice_audio_url, _voice_loading: false });
    } else if (response.status !== 202) {
      updateMessage(messageId, { _voice_loading: false });
    }
    // 202: loading state clears when Broadcastable refresh replaces the message
  } catch {
    updateMessage(messageId, { _voice_loading: false });
  }
}
```

Check whether a helper like `updateMessage` already exists on `show.svelte` -- if other features do the same pattern, this might deserve to be a shared utility. But even locally, eliminating the triple-map is a clear win.

### 5. The `voice_audio_url` method should follow the existing `audio_url` pattern exactly

The spec proposes:

```ruby
def voice_audio_url
  return unless voice_audio.attached?
  Rails.application.routes.url_helpers.rails_blob_url(voice_audio, only_path: true)
rescue ArgumentError
  nil
end
```

The existing `audio_url` method at line 200-205 of `message.rb` is:

```ruby
def audio_url
  return unless audio_recording.attached?
  Rails.application.routes.url_helpers.rails_blob_url(audio_recording, only_path: true)
rescue ArgumentError
  nil
end
```

These are identical in structure, which is good -- the spec correctly mirrors the existing pattern. But now there are two methods that are structurally identical, differing only in the attachment name. If a third attachment type ever comes along, this will be three copy-pasted methods.

**Recommendation**: Consider a small private helper, but do not over-engineer this. Two is tolerable. Just be aware of the pattern.

### 6. The `voice_settings` JSONB column may be premature

The spec adds `voice_settings` as a JSONB column with defaults for stability, similarity_boost, style, speed, and use_speaker_boost. Then in Step 12 (seed data), every agent gets *identical* voice settings. And the requirements say: "No UI needed for configuring these yet -- set via console."

If every agent has the same settings, the `DEFAULT_VOICE_SETTINGS` constant in `ElevenLabsTts` already handles this. The column adds a migration, a parameter pipe through the controller/job/model, and seed data -- all for values that are currently identical across all agents.

**Recommendation**: Drop `voice_settings` from the migration. Keep only `voice_id`. The `ElevenLabsTts` class already has `DEFAULT_VOICE_SETTINGS`. When an agent eventually needs custom settings, add the column then. You Aren't Gonna Need It.

```ruby
class AddVoiceToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :voice_id, :string
  end
end
```

The TTS call simplifies to:

```ruby
ElevenLabsTts.synthesize(text, voice_id: agent.voice_id)
```

If custom per-agent settings become necessary later, add the column in a future migration. Columns are cheap to add.

### 7. The `Spinner` import name collision

The spec imports `Spinner as SpinnerIcon` in MessageBubble because `Spinner` is already imported. The existing import at line 5 is:

```javascript
import { ArrowClockwise, Spinner, Globe, PencilSimple, Trash, Wrench } from 'phosphor-svelte';
```

The spec adds:

```javascript
import { SpeakerSimpleHigh, Spinner as SpinnerIcon } from 'phosphor-svelte';
```

This is a single import statement in the same file from the same package. Just add `SpeakerSimpleHigh` to the existing import and reuse `Spinner` -- no need for an alias:

```javascript
import { ArrowClockwise, Spinner, Globe, PencilSimple, Trash, Wrench, SpeakerSimpleHigh } from 'phosphor-svelte';
```

Then use `Spinner` (not `SpinnerIcon`) in the loading state.

### 8. The voice button placement should not be inside `Card.Content`

The spec places the voice button inside `Card.Content`, after the tools_used section. Looking at the existing MessageBubble, the user audio player at lines 123-127 is placed *outside* the Card entirely:

```svelte
{#if message.audio_source && message.audio_url}
  <div class="mt-1 flex justify-end">
    <AudioPlayer src={message.audio_url} />
  </div>
{/if}
```

For visual consistency, the agent voice controls should mirror this placement -- outside and below the Card, not inside it. This also avoids adding a `border-t` divider inside the card content, which is a visual choice that will look different from the user audio player.

**Recommendation**: Place the voice controls after the agent message's metadata section (after line 213), mirroring the user message audio placement:

```svelte
{#if message.voice_available && !message.streaming}
  <div class="mt-1">
    {#if message.voice_audio_url}
      <AudioPlayer src={message.voice_audio_url} />
    {:else if message._voice_loading}
      <div class="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
        <Spinner size={14} class="animate-spin" />
        <span>Generating voice...</span>
      </div>
    {:else}
      <button
        onclick={() => onvoice(message.id)}
        class="inline-flex items-center gap-1.5 text-xs text-muted-foreground
               hover:text-foreground transition-colors"
        title="Play voice">
        <SpeakerSimpleHigh size={14} weight="duotone" />
        <span>Listen</span>
      </button>
    {/if}
  </div>
{/if}
```

---

## What Works Well

1. **The architecture is genuinely simple.** Ten files, no new components, no new gems, no new ActionCable channels. The existing `Broadcastable` concern handles the real-time update for free. This is Rails at its best -- leveraging what you already have.

2. **The `ElevenLabsTts` class mirrors the `ElevenLabsStt` pattern perfectly.** Same structure, same error handling, same credential access. A developer familiar with one will immediately understand the other. This is what convention over configuration looks like in practice.

3. **The job is lean and correct.** The guard clauses at the top (`return if message.voice_audio.attached?`, `return unless message.voice_available`) handle all the edge cases without ceremony. `retry_on` and `discard_on` are used appropriately. The Broadcastable refresh is leveraged rather than reinvented.

4. **The route placement follows the established pattern exactly.** `resource :voice` sits alongside `resource :retry` and `resource :hallucination_fix` under the top-level `messages` resource. No new nesting, no new namespaces.

5. **The testing strategy is thorough and follows project conventions.** VCR cassettes for real API calls (no mocks), model tests for the transformation logic, controller tests for the HTTP contract, and edge case coverage. The spec even tests the *negative* cases (no voice for user messages, no voice when agent lacks voice_id).

6. **The cost control decisions are sound.** On-demand rendering, S3 caching, character truncation, no auto-play. These are product decisions embedded in the architecture, not afterthoughts.

7. **The decision to use `broadcasts_to :chat` for the real-time update is elegant.** No custom ActionCable wiring, no WebSocket messages to define, no subscription management. The message saves, the broadcast fires, the frontend refreshes. Three moving parts, zero new infrastructure.

8. **The system prompt update (Step 11) is appropriately minimal.** A small conditional append, not a rewrite of the prompt assembly logic.

---

## Summary of Recommended Changes

| Priority | Change | Effort |
|----------|--------|--------|
| High | Extract shared `set_message_and_chat` into `Messages::BaseController` | Small |
| High | Drop `voice_settings` column -- use defaults until per-agent tuning is needed | Small (simplifies) |
| Medium | Extract `content_for_speech` into `Message::SpeechText` value object | Small |
| Medium | DRY up the frontend `requestVoice` with an `updateMessage` helper | Small |
| Low | Fix `Spinner` import -- add `SpeakerSimpleHigh` to existing import line | Trivial |
| Low | Place voice controls outside Card.Content to match user audio placement | Trivial |
| Low | Clean up requirements doc contradiction about background jobs | Trivial |
