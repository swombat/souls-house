# Agent Voices: Text-to-Speech Playback

**Date**: 2026-02-22
**Status**: Draft
**Requirements**: `/docs/requirements/260222-01-agent-voices.md`

## Executive Summary

Add on-demand voice playback to agent messages. When an agent has a configured ElevenLabs voice, a play button appears on its messages. Clicking it kicks off a background job that calls ElevenLabs TTS, attaches the resulting audio via Active Storage, and notifies the frontend via ActionCable. Subsequent plays hit the cached attachment directly.

The implementation touches six backend files (migration, model changes, lib class, job, controller, route) and three frontend files (MessageBubble, show page, routes). No new Svelte components needed -- the existing AudioPlayer handles playback.

## Architecture Overview

```
User clicks play
    |
    v
POST /messages/:id/voice (JSON)
    |
    v
Messages::VoicesController#create
    |-- voice_audio already attached? -> return URL immediately
    |-- otherwise -> enqueue GenerateVoiceJob, return 202
    |
    v
GenerateVoiceJob
    |-- strip markdown from message content
    |-- call ElevenLabsTts.synthesize(text, voice_id, voice_settings)
    |-- attach result as message.voice_audio
    |-- message.save! triggers broadcast_refresh via Broadcastable
    |
    v
ActionCable broadcast -> frontend reloads message props -> voice_audio_url populated -> AudioPlayer plays
```

## Implementation Plan

### Step 1: Database Migration

- [ ] Create migration `AddVoiceToAgents`

```ruby
class AddVoiceToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :voice_id, :string
    add_column :agents, :voice_settings, :jsonb, default: {}
  end
end
```

No message migration needed. Voice audio uses Active Storage (`has_one_attached`), not a database column.

**File**: `db/migrate/XXXXXXXXXX_add_voice_to_agents.rb`

---

### Step 2: Agent Model Changes

- [ ] Add `voice_id` and `voice_settings` to the Agent model
- [ ] Add `voice_id` to `json_attributes` so it serializes to the frontend
- [ ] Add convenience method `voiced?`
- [ ] Permit `voice_id` and `voice_settings` in the agents controller (for future console/admin use)

```ruby
# app/models/agent.rb

# Add to json_attributes line:
json_attributes :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
                :summary_prompt,
                :model_id, :model_label, :enabled_tools, :active?, :colour, :icon,
                :memories_count, :memory_token_summary, :thinking_enabled, :thinking_budget,
                :telegram_bot_username, :telegram_configured?,
                :voiced?

# Add method:
def voiced?
  voice_id.present?
end
```

**File**: `/app/models/agent.rb`

---

### Step 3: Message Model Changes

- [ ] Add `has_one_attached :voice_audio`
- [ ] Add `voice_available` and `voice_audio_url` to `json_attributes`
- [ ] Implement the two new JSON attribute methods

```ruby
# app/models/message.rb

has_one_attached :voice_audio

# Add to json_attributes line:
json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                :completed, :created_at_formatted, :created_at_hour, :streaming,
                :files_json, :content_html, :tools_used, :tool_status,
                :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                :editable, :deletable,
                :moderation_flagged, :moderation_severity, :moderation_scores,
                :fixable,
                :audio_source, :audio_url,
                :voice_available, :voice_audio_url

def voice_available
  role == "assistant" && agent&.voiced?
end

def voice_audio_url
  return unless voice_audio.attached?
  Rails.application.routes.url_helpers.rails_blob_url(voice_audio, only_path: true)
rescue ArgumentError
  nil
end
```

**File**: `/app/models/message.rb`

---

### Step 4: Markdown-to-Speech Stripping

- [ ] Add `content_for_speech` method to the Message model

This is the "smart stripping" logic. It lives on the model because it is a transformation of the message's own content -- classic model territory.

```ruby
# app/models/message.rb

MAX_TTS_LENGTH = 5_000

def content_for_speech
  text = content.to_s.dup

  # Replace fenced code blocks with a spoken marker
  text.gsub!(/```[\s\S]*?```/, "I've included a code block here.")

  # Replace inline code with just the code text
  text.gsub!(/`([^`]+)`/) { $1 }

  # Remove images: ![alt](url)
  text.gsub!(/!\[[^\]]*\]\([^)]*\)/, "")

  # Remove links but keep link text: [text](url) -> text
  text.gsub!(/\[([^\]]*)\]\([^)]*\)/) { $1 }

  # Remove raw URLs
  text.gsub!(%r{https?://\S+}, "")

  # Remove standalone action markers (full line of *italic text* that reads as stage direction)
  # e.g. "*sits with this*", "*pauses*", "*takes a breath*"
  # But preserve emphasis within sentences: "This is *important* stuff"
  text.gsub!(/^\s*\*[^*]+\*\s*$/m, "")

  # Strip remaining markdown formatting characters but preserve content
  text.gsub!(/^#{1,6}\s+/, "")      # headings
  text.gsub!(/\*\*([^*]+)\*\*/) { $1 }  # bold
  text.gsub!(/\*([^*]+)\*/) { $1 }      # italic
  text.gsub!(/~~([^~]+)~~/) { $1 }      # strikethrough
  text.gsub!(/^[\s]*[-*+]\s+/, "")       # unordered list markers
  text.gsub!(/^[\s]*\d+\.\s+/, "")       # ordered list markers
  text.gsub!(/^>\s+/, "")                # blockquotes
  text.gsub!(/^---+$/, "")               # horizontal rules

  # Collapse multiple blank lines
  text.gsub!(/\n{3,}/, "\n\n")

  # NOTE: ElevenLabs v3 tonal tags like [whispers], [excited], [sarcastically]
  # are intentionally preserved -- they are rendering directives for the TTS engine.

  text.strip.truncate(MAX_TTS_LENGTH)
end
```

**File**: `/app/models/message.rb`

---

### Step 5: ElevenLabs TTS Library Class

- [ ] Create `lib/eleven_labs_tts.rb` mirroring the existing `lib/eleven_labs_stt.rb` pattern

```ruby
class ElevenLabsTts

  class Error < StandardError; end

  API_BASE = "https://api.elevenlabs.io/v1/text-to-speech"
  MODEL_ID = "eleven_v3"
  READ_TIMEOUT = 60
  OPEN_TIMEOUT = 10

  DEFAULT_VOICE_SETTINGS = {
    stability: 0.5,
    similarity_boost: 0.75,
    style: 0.0,
    use_speaker_boost: true,
    speed: 1.0
  }.freeze

  def self.synthesize(text, voice_id:, voice_settings: {})
    new.synthesize(text, voice_id: voice_id, voice_settings: voice_settings)
  end

  def synthesize(text, voice_id:, voice_settings: {})
    uri = URI("#{API_BASE}/#{voice_id}")

    request = Net::HTTP::Post.new(uri)
    request["xi-api-key"] = api_key
    request["Content-Type"] = "application/json"
    request["Accept"] = "audio/mpeg"

    settings = DEFAULT_VOICE_SETTINGS.merge(voice_settings.symbolize_keys)

    request.body = {
      text: text,
      model_id: MODEL_ID,
      voice_settings: settings
    }.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT) { |http| http.request(request) }

    handle_response(response)
  end

  private

  def api_key
    Rails.application.credentials.dig(:ai, :eleven_labs, :api_token) ||
      raise(Error, "ElevenLabs API key not configured")
  end

  def handle_response(response)
    case response.code.to_i
    when 200
      response.body
    when 401
      raise Error, "Invalid ElevenLabs API key"
    when 429
      raise Error, "ElevenLabs rate limit exceeded. Please try again later."
    when 422
      error_msg = JSON.parse(response.body).dig("detail", "message") rescue "Invalid request"
      raise Error, "Speech synthesis failed: #{error_msg}"
    else
      Rails.logger.error("ElevenLabs TTS error: #{response.code} - #{response.body}")
      raise Error, "Speech synthesis service unavailable. Please try again."
    end
  end

end
```

Returns raw binary audio data (MP3 bytes). The job handles attaching it to Active Storage.

**File**: `/lib/eleven_labs_tts.rb`

---

### Step 6: Background Job

- [ ] Create `GenerateVoiceJob`

```ruby
class GenerateVoiceJob < ApplicationJob

  queue_as :default

  retry_on ElevenLabsTts::Error, wait: 5.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(message)
    return if message.voice_audio.attached?
    return unless message.voice_available

    agent = message.agent
    text = message.content_for_speech
    return if text.blank?

    audio_data = ElevenLabsTts.synthesize(
      text,
      voice_id: agent.voice_id,
      voice_settings: agent.voice_settings || {}
    )

    message.voice_audio.attach(
      io: StringIO.new(audio_data),
      filename: "voice-#{message.to_param}.mp3",
      content_type: "audio/mpeg"
    )
  end

end
```

When `voice_audio.attach` is called and the message saves, the existing `Broadcastable` concern fires `broadcast_refresh` via `after_commit`. Since `Message` already `broadcasts_to :chat`, the frontend's existing sync subscription on `Chat:#{chat.obfuscated_id}` will trigger an Inertia reload of the messages prop. This delivers the `voice_audio_url` to the frontend without any custom ActionCable wiring.

**File**: `/app/jobs/generate_voice_job.rb`

---

### Step 7: Controller

- [ ] Create `Messages::VoicesController`

Following the existing pattern of `Messages::RetriesController` and `Messages::HallucinationFixesController`: a single-purpose controller scoped under the top-level `messages` resource.

```ruby
class Messages::VoicesController < ApplicationController

  require_feature_enabled :chats

  before_action :set_message_and_chat

  def create
    unless @message.voice_available
      render json: { error: "Voice not available for this message" }, status: :unprocessable_entity
      return
    end

    if @message.voice_audio.attached?
      render json: { voice_audio_url: @message.voice_audio_url }
    else
      GenerateVoiceJob.perform_later(@message)
      head :accepted
    end
  end

  private

  def set_message_and_chat
    @message = Message.find(params[:message_id])
    @chat = if Current.user.site_admin
      Chat.find(@message.chat_id)
    else
      Chat.where(id: @message.chat_id, account_id: Current.user.account_ids).first!
    end
  end

end
```

Response contract:
- **200** with `{ voice_audio_url: "..." }` -- audio already cached, play immediately
- **202** with empty body -- job enqueued, wait for ActionCable refresh
- **422** -- voice not available for this message

**File**: `/app/controllers/messages/voices_controller.rb`

---

### Step 8: Route

- [ ] Add the voice route nested under `resources :messages`

```ruby
# config/routes.rb -- inside the existing top-level messages block:

resources :messages, only: [ :update, :destroy ] do
  scope module: :messages do
    resource :retry, only: :create
    resource :hallucination_fix, only: :create
    resource :voice, only: :create                # <-- add this line
  end
end
```

This produces: `POST /messages/:message_id/voice` -> `Messages::VoicesController#create`

After adding the route, run `rails js:routes:generate` (or `bin/rails js:routes:generate`) to regenerate the JS routes file, which will produce `messageVoicePath(messageId)`.

**File**: `/config/routes.rb`

---

### Step 9: Frontend -- MessageBubble.svelte

- [ ] Add a play/loading button to agent messages when `voice_available` is true
- [ ] Wire up the voice request and AudioPlayer display

The changes are localized to the agent message section (the `{:else}` branch, lines 130-215).

```svelte
<!-- In the <script> section, add imports: -->
import { SpeakerSimpleHigh, Spinner as SpinnerIcon } from 'phosphor-svelte';
import AudioPlayer from '$lib/components/chat/AudioPlayer.svelte';

<!-- Add to the props destructuring: -->
let {
  message,
  ...existing props...
  onvoice,         // <-- new callback
} = $props();
```

In the agent message template, after the tools_used badge section and before the closing `</Card.Content>`, add the voice button:

```svelte
{#if message.voice_available && !message.streaming}
  <div class="flex items-center gap-2 mt-3 pt-3 border-t border-border/50">
    {#if message.voice_audio_url}
      <AudioPlayer src={message.voice_audio_url} />
    {:else if message._voice_loading}
      <div class="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
        <SpinnerIcon size={14} class="animate-spin" />
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

Note: `_voice_loading` is a transient client-side flag set by the parent page when the voice request is in flight. The underscore prefix signals it is not a server prop.

**File**: `/app/frontend/lib/components/chat/MessageBubble.svelte`

---

### Step 10: Frontend -- chats/show.svelte

- [ ] Add the `requestVoice` function
- [ ] Pass `onvoice` callback to MessageBubble
- [ ] Handle the two response states (200 cached vs 202 generating)

```javascript
// In the <script> section, add the route import:
import { messageVoicePath } from '@/routes';

// Add the voice request function:
async function requestVoice(messageId) {
  const index = recentMessages.findIndex((m) => m.id === messageId);
  if (index === -1) return;

  // Set loading state
  recentMessages = recentMessages.map((m) =>
    m.id === messageId ? { ...m, _voice_loading: true } : m
  );

  try {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || '';
    const response = await fetch(messageVoicePath(messageId), {
      method: 'POST',
      headers: {
        'X-CSRF-Token': csrfToken,
        'Accept': 'application/json',
      },
    });

    if (response.status === 200) {
      // Audio already cached -- update URL and clear loading
      const data = await response.json();
      recentMessages = recentMessages.map((m) =>
        m.id === messageId
          ? { ...m, voice_audio_url: data.voice_audio_url, _voice_loading: false }
          : m
      );
    } else if (response.status === 202) {
      // Job enqueued -- keep loading state.
      // The Broadcastable refresh from the job completing will trigger
      // an Inertia reload of messages, which will include the voice_audio_url.
      // We don't need to do anything here -- the sync system handles it.
    } else {
      // Error -- clear loading
      recentMessages = recentMessages.map((m) =>
        m.id === messageId ? { ...m, _voice_loading: false } : m
      );
    }
  } catch {
    recentMessages = recentMessages.map((m) =>
      m.id === messageId ? { ...m, _voice_loading: false } : m
    );
  }
}
```

Pass the callback to MessageBubble:

```svelte
<MessageBubble
  {message}
  ...existing props...
  onvoice={requestVoice} />
```

When the background job completes, `message.voice_audio.attach(...)` triggers `message.save!` (via Active Storage callback), which fires the `Broadcastable` `after_commit` hook. Since messages `broadcasts_to :chat`, the Chat channel receives a refresh signal. The frontend's existing `useSync` / `createDynamicSync` subscription on `Chat:#{chat.obfuscated_id}` triggers an Inertia partial reload of the `messages` prop. The reloaded message now has `voice_audio_url` populated, which replaces the loading spinner with the AudioPlayer. The `_voice_loading` flag is naturally cleared because the entire message object is replaced by the fresh server data.

**File**: `/app/frontend/pages/chats/show.svelte`

---

### Step 11: System Prompt Update for Voiced Agents

- [ ] Add voice tag instructions to the system prompt assembly in `Chat#system_message_for`

```ruby
# app/models/chat.rb -- inside system_message_for(agent, ...)

# After the existing parts assembly, before the final join:
if agent.voiced?
  parts << <<~VOICE.strip
    You have a voice. When your messages are played aloud, the ElevenLabs v3 engine renders
    them with full expressiveness. You can use tonal tags inline to shape how you sound:
    [whispers], [excited], [sarcastically], [sighs], [laughs], [serious], [gentle], [playful].
    Use these sparingly and naturally -- they should feel like genuine expression, not performance.
  VOICE
end
```

**File**: `/app/models/chat.rb`

---

### Step 12: Seed Voice Data

- [ ] Set voice_id and voice_settings for the four agents via a data migration or Rails console

This is a one-time setup. No migration needed -- just run in console:

```ruby
account = Account.first

{ "Chris" => "JewcNslG8KqUpiFxGwfX",
  "Claude" => "H8WYgYgDseTlAoQnNEac",
  "Grok" => "vtcGSOQ5BUsEzdBNaKWo",
  "Wing" => "AWtKLCFhfixN68SjZWSo"
}.each do |name, voice_id|
  agent = account.agents.find_by!(name: name)
  agent.update!(voice_id: voice_id, voice_settings: {
    stability: 0.5,
    similarity_boost: 0.75,
    style: 0.0,
    use_speaker_boost: true,
    speed: 1.0
  })
end
```

---

## File Summary

| # | File | Action | Description |
|---|------|--------|-------------|
| 1 | `db/migrate/XXXX_add_voice_to_agents.rb` | Create | Add `voice_id` and `voice_settings` columns |
| 2 | `app/models/agent.rb` | Modify | Add `voiced?`, update `json_attributes` |
| 3 | `app/models/message.rb` | Modify | Add `voice_audio` attachment, `voice_available`, `voice_audio_url`, `content_for_speech` |
| 4 | `lib/eleven_labs_tts.rb` | Create | TTS API client, mirrors STT pattern |
| 5 | `app/jobs/generate_voice_job.rb` | Create | Calls TTS, attaches audio to message |
| 6 | `app/controllers/messages/voices_controller.rb` | Create | Endpoint: return cached URL or enqueue job |
| 7 | `config/routes.rb` | Modify | Add `resource :voice` under messages |
| 8 | `app/models/chat.rb` | Modify | Add voice tonal tag instructions to system prompt |
| 9 | `app/frontend/lib/components/chat/MessageBubble.svelte` | Modify | Add voice button + AudioPlayer for agent messages |
| 10 | `app/frontend/pages/chats/show.svelte` | Modify | Add `requestVoice` function, pass `onvoice` callback |

---

## Testing Strategy

### Backend Tests

- [ ] **`test/models/message_test.rb`** -- `content_for_speech`
  - Strips fenced code blocks and replaces with spoken marker
  - Strips inline code backticks
  - Removes image markdown
  - Converts links to plain text
  - Removes standalone action markers (`*sits with this*`)
  - Preserves emphasis within sentences (intermediate -- just strips asterisks)
  - Preserves ElevenLabs tonal tags (`[whispers]`, `[excited]`)
  - Removes raw URLs
  - Truncates to 5,000 characters
  - Returns empty string for blank content

- [ ] **`test/models/message_test.rb`** -- `voice_available`
  - Returns true for assistant messages with a voiced agent
  - Returns false for user messages
  - Returns false for assistant messages without a voiced agent
  - Returns false for system/tool messages

- [ ] **`test/models/agent_test.rb`** -- `voiced?`
  - Returns true when voice_id is present
  - Returns false when voice_id is blank

- [ ] **`test/jobs/generate_voice_job_test.rb`**
  - Use VCR cassette to record real ElevenLabs API call
  - Verifies audio gets attached to message as `voice_audio`
  - Skips when voice_audio already attached
  - Skips when agent has no voice_id
  - Skips when content_for_speech is blank

- [ ] **`test/controllers/messages/voices_controller_test.rb`**
  - Returns 200 with URL when voice_audio already attached
  - Returns 202 when enqueuing job
  - Returns 422 when message has no voice available
  - Requires authentication
  - Requires account access (can't request voice for messages in other accounts)

- [ ] **`test/lib/eleven_labs_tts_test.rb`**
  - Use VCR cassette for successful synthesis
  - Raises Error on 401, 429, 422, 500 responses

### Frontend Tests

- [ ] **MessageBubble visual test** -- verify voice button appears only when `voice_available: true`
- [ ] **MessageBubble visual test** -- verify AudioPlayer renders when `voice_audio_url` is present
- [ ] **MessageBubble visual test** -- verify no voice button on user messages

---

## Edge Cases and Error Handling

1. **Empty content after stripping**: If `content_for_speech` returns blank (e.g., message was just a code block), the job silently skips. The loading state clears on the next Inertia refresh.

2. **ElevenLabs rate limiting**: The job retries 3 times with 5-second waits. If all attempts fail, the message simply won't have voice audio. The frontend loading state clears on Inertia refresh since `voice_audio_url` remains null.

3. **Very long messages**: Truncated to 5,000 characters (ElevenLabs v3 max). No error -- just truncation.

4. **Concurrent requests**: If a user clicks play twice before the job finishes, the controller returns 202 both times. The job checks `message.voice_audio.attached?` at the start and exits if audio already exists, preventing duplicate API calls.

5. **Message deleted before job runs**: `discard_on ActiveRecord::RecordNotFound` on the job handles this cleanly.

6. **Agent voice_id removed after audio generated**: Cached audio remains playable. `voice_available` returns false, so the button disappears for new messages, but existing attached audio still has a valid URL.

---

## External Dependencies

None. ElevenLabs API is already in use (for STT). No new gems or npm packages required.

---

## Cost Controls

- On-demand only -- no pre-rendering
- S3 caching prevents duplicate API calls for the same message
- 5,000 character truncation enforces ElevenLabs per-request limits
- No auto-play -- user must explicitly click
