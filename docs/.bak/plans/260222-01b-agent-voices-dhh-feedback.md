# DHH Review: Agent Voices Implementation Spec (v2)

**Date**: 2026-02-22
**Reviewing**: `/docs/plans/260222-01b-agent-voices.md`
**Previous Review**: `/docs/plans/260222-01a-agent-voices-dhh-feedback.md`

---

## Overall Assessment

This is a materially improved spec. Every critical issue from the v1 review was addressed -- the `Messages::BaseController` extraction, the `Message::SpeechText` value object, the YAGNI removal of `voice_settings`, the `updateMessage` helper, the icon import fix, and the voice control placement. The architecture remains lean: fourteen files, no new gems, no custom ActionCable channels, and genuine reuse of existing infrastructure (Broadcastable, Active Storage, AudioPlayer). This is close to shipworthy Rails work.

There is one significant omission: the updated requirements now call for a voice configuration field on the agent edit page, and the spec does not address it at all. The seed-data-via-console approach from Step 13 was appropriate before the requirement changed, but now the spec needs a frontend component and a controller parameter. Beyond that, there are a few smaller issues worth cleaning up before implementation begins.

---

## Critical Issues

### 1. Missing: Voice configuration UI on the agent edit page

The requirements document (`/docs/requirements/260222-01-agent-voices.md`) now explicitly states:

> The agent edit/setup page should include a voice configuration field where the user can select from pre-defined voices (the saved ElevenLabs voices) or type a voice ID directly.

The spec has no step for this. Step 13 (seed data via console) is a holdover from the original "no UI" approach. The edit page at `/app/frontend/pages/agents/edit.svelte` already has five tabs (identity, appearance, model, integrations, memory). This needs to be addressed.

**What is needed:**

**Backend** -- two changes to `AgentsController`:

```ruby
# app/controllers/agents_controller.rb

# In agent_params, permit :voice_id
def agent_params
  params.require(:agent).permit(
    :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
    :summary_prompt,
    :model_id, :active, :colour, :icon,
    :thinking_enabled, :thinking_budget,
    :telegram_bot_token, :telegram_bot_username,
    :voice_id,
    enabled_tools: []
  )
end

# In edit action, pass available voices
def edit
  render inertia: "agents/edit", props: {
    agent: @agent.as_json.merge(
      "telegram_bot_token" => @agent.telegram_bot_token,
      "voice_id" => @agent.voice_id
    ),
    available_voices: available_voices,
    # ... existing props
  }
end

private

def available_voices
  # Static list of saved voices from ElevenLabs account
  # Could be moved to a config constant or fetched from ElevenLabs API later
  [
    { id: "JewcNslG8KqUpiFxGwfX", name: "Chris (Deep British baritone)" },
    { id: "H8WYgYgDseTlAoQnNEac", name: "Claude (Soft androgynous)" },
    { id: "vtcGSOQ5BUsEzdBNaKWo", name: "Grok (Mediterranean, husky)" },
    { id: "AWtKLCFhfixN68SjZWSo", name: "Wing (Androgynous, warm)" },
  ]
end
```

**Frontend** -- add a voice field to the identity tab in `edit.svelte`. This fits naturally under the "Active" toggle. A combobox-style input: dropdown of known voices plus a free-text option for custom voice IDs:

```svelte
<!-- In the identity tab, after the Active toggle -->
<div class="space-y-2">
  <Label for="voice_id">Voice</Label>
  <select
    id="voice_id"
    bind:value={$form.agent.voice_id}
    class="w-full max-w-md border border-input rounded-md px-3 py-2 text-sm bg-background
           focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent">
    <option value="">No voice</option>
    {#each available_voices as voice (voice.id)}
      <option value={voice.id}>{voice.name}</option>
    {/each}
  </select>
  <p class="text-xs text-muted-foreground">
    Select a voice for text-to-speech playback, or leave empty to disable voice.
  </p>
</div>
```

If the user needs to paste an arbitrary ElevenLabs voice ID, a simple `<Input>` field below the dropdown (shown conditionally when "Custom..." is selected) handles that. But start with just the dropdown of known voices. The requirement says "dropdown of pre-defined voices plus the ability to type a voice ID directly" -- so a native `<select>` with the known voices, plus one more `<option value="custom">Custom voice ID...</option>` that reveals a text input, is the simplest approach. Do not build a voice browser or a search UI.

Also add `voice_id` to the agent's `json_attributes` so it flows through `as_json`:

```ruby
json_attributes :name, :system_prompt, ..., :voiced?, :voice_id
```

And add `voice_id` to the `useForm` initialization in `edit.svelte`:

```javascript
let form = useForm({
  agent: {
    // ... existing fields
    voice_id: agent.voice_id || '',
  },
});
```

This is the one genuinely missing piece. Everything else in the spec can ship as-is with minor tweaks.

### 2. The `HallucinationFixesController` refactor has a subtle authorization change

The spec proposes that `Messages::BaseController` uses:

```ruby
def set_message_and_chat
  @message = Message.find(params[:message_id])
  @chat = current_account.chats.find(@message.chat_id)
end
```

This replaces the existing `HallucinationFixesController` pattern which has a special `site_admin` bypass:

```ruby
@chat = if Current.user.site_admin
  Chat.find(@message.chat_id)
else
  Chat.where(id: @message.chat_id, account_id: Current.user.account_ids).first!
end
```

The v1 review correctly identified this as a divergence and recommended standardizing on the simpler `current_account.chats.find` pattern, which the `RetriesController` already uses successfully. However, the spec should explicitly acknowledge that this is a behavioral change for `HallucinationFixesController`. If `site_admin` users currently rely on the bypass to fix hallucinations in chats they don't own via `current_account`, this refactor will break that. Verify that `current_account` for site admins can reach all chats they need before shipping.

This is not a code quality issue -- it is a correctness issue. Add a note to Step 7 confirming that the `AccountScoping` concern's `current_account` already handles site admin access, or add a test for it.

---

## Improvements Needed

### 3. Step 13 should be replaced, not just supplemented

Step 13 currently says "Set voice_id for the four agents via Rails console." With the new UI, this step becomes a one-time migration convenience, not an ongoing process. Either:

- Remove Step 13 entirely and let the user set voices through the new UI after deploying, or
- Keep it as a one-time data migration in the deployment notes, but clearly label it as "initial seed, superseded by UI"

Do not leave it as an implementation step that implies console access is the long-term workflow.

### 4. The `voice_audio_url` duplication is now worth addressing

The v1 review noted the structural duplication between `audio_url` and `voice_audio_url` and said "two is tolerable." That remains true. But since the spec is already extracting `Message::SpeechText` as a value object to keep the model clean, consider whether a tiny helper method is warranted:

```ruby
private

def blob_url_for(attachment)
  return unless attachment.attached?
  Rails.application.routes.url_helpers.rails_blob_url(attachment, only_path: true)
rescue ArgumentError
  nil
end
```

Then:

```ruby
def audio_url = blob_url_for(audio_recording)
def voice_audio_url = blob_url_for(voice_audio)
```

This is a judgment call -- two one-liner delegations are arguably cleaner than two five-line methods that are structurally identical. But if you leave it as-is, that is also fine.

### 5. The `requestVoice` function's CSRF token retrieval is duplicated

Looking at `show.svelte`, the `fixHallucinatedToolCalls` function already does:

```javascript
const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || '';
```

The new `requestVoice` function does the same thing. This is the third time this pattern appears in the file (the `deleteMessage` function also uses it). Consider extracting a tiny helper at the top of the script:

```javascript
function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || '';
}
```

Then every fetch call uses `csrfToken()` instead of repeating the DOM query. This is a small DRY improvement that the spec should call out since it is already touching this file.

### 6. The `updateMessage` helper should also update `olderMessages`

The spec introduces:

```javascript
function updateMessage(messageId, patch) {
  recentMessages = recentMessages.map((m) =>
    m.id === messageId ? { ...m, ...patch } : m
  );
}
```

But the existing `deleteMessage` and `onsaved` callbacks in `show.svelte` update *both* `recentMessages` and `olderMessages`. The `updateMessage` helper only touches `recentMessages`. If the user scrolls up to an older message and clicks "Listen," the voice loading state will not be applied because that message lives in `olderMessages`.

Fix:

```javascript
function updateMessage(messageId, patch) {
  recentMessages = recentMessages.map((m) =>
    m.id === messageId ? { ...m, ...patch } : m
  );
  olderMessages = olderMessages.map((m) =>
    m.id === messageId ? { ...m, ...patch } : m
  );
}
```

This also makes the helper useful for the existing `onsaved` callback, which currently does this manually.

---

## What Works Well

1. **Every v1 feedback item was addressed.** The `Messages::BaseController` extraction, `Message::SpeechText` value object, YAGNI removal of `voice_settings`, the `updateMessage` helper, the icon import fix, and the voice control placement outside `Card.Content`. This shows good spec discipline.

2. **The `Message::SpeechText` value object is well-designed.** Each regex gets a named method. The `to_s` method reads like a pipeline. It is independently testable. The decision to preserve ElevenLabs tonal tags (`[whispers]`, etc.) by not having any rule that matches square brackets is elegant -- correctness through omission rather than special-case handling.

3. **The `Messages::BaseController` extraction is clean.** Three controllers sharing one base class with a single `before_action`. The refactored `RetriesController` and `HallucinationFixesController` are visibly simpler. This is the kind of refactoring that pays for itself immediately.

4. **The TTS class remains a faithful mirror of the STT class.** Same structure, same constant naming, same error handling, same credential access pattern. A developer who knows one knows the other.

5. **The Broadcastable-driven refresh is still the best architectural decision in this spec.** No custom ActionCable channels, no WebSocket message types, no frontend subscription management. The job attaches audio, the message saves, the broadcast fires, the frontend refreshes. Zero new infrastructure.

6. **The testing strategy covers the value object independently.** The `Message::SpeechText` tests are the most important tests in this feature -- they verify twelve distinct transformation behaviors. Getting the stripping wrong means sending garbage to ElevenLabs. These tests pay for themselves.

7. **The edge cases section is thorough.** Concurrent clicks, empty content after stripping, rate limiting, message deletion before job completion, voice removal after audio generation. Each is handled with a one-sentence explanation that demonstrates the author understands the failure mode.

---

## Summary of Recommended Changes

| Priority | Change | Effort |
|----------|--------|--------|
| **High** | Add voice configuration UI to agent edit page (new requirement) | Small-Medium |
| **High** | Add `voice_id` to `agent_params` in `AgentsController` | Trivial |
| **High** | Add `voice_id` to agent `json_attributes` | Trivial |
| **Medium** | Verify `current_account` handles site admin access for HallucinationFixes refactor | Small |
| **Medium** | Make `updateMessage` helper update both `recentMessages` and `olderMessages` | Trivial |
| **Low** | Replace Step 13 (console seed) with UI-first approach | Trivial |
| **Low** | Extract `csrfToken()` helper in `show.svelte` | Trivial |
| **Low** | Consider `blob_url_for` private helper to DRY `audio_url`/`voice_audio_url` | Trivial |

The spec is solid architecture. The main gap is the missing UI for voice configuration -- which is now a stated requirement. Address that, fix the `updateMessage` scope to include `olderMessages`, and this is ready to build.
