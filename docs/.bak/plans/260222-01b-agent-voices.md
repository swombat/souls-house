# Agent Voices: Text-to-Speech Playback (v2)

**Date**: 2026-02-22
**Status**: Draft
**Requirements**: `/docs/requirements/260222-01-agent-voices.md`
**Previous**: `/docs/plans/260222-01a-agent-voices.md`
**Review**: `/docs/plans/260222-01a-agent-voices-dhh-feedback.md`

## Executive Summary

Add on-demand voice playback to agent messages. When an agent has a configured ElevenLabs voice, a play button appears on its messages. Clicking it kicks off a background job that calls ElevenLabs TTS, attaches the audio via Active Storage, and notifies the frontend via the existing `Broadcastable` concern. Subsequent plays hit the cached attachment directly.

Changes from v1 based on DHH review:
- Extract `Messages::BaseController` to DRY up authorization across VoicesController, RetriesController, and HallucinationFixesController
- Extract `Message::SpeechText` value object for markdown-to-speech stripping
- Drop `voice_settings` JSONB column (YAGNI -- defaults in the TTS class suffice)
- Extract `updateMessage` helper in show.svelte to eliminate triple-map
- Fix icon imports (add to existing import, no alias)
- Place voice controls outside `Card.Content` to match user audio placement

## Architecture Overview

```
User clicks play
    |
    v
POST /messages/:id/voice (JSON)
    |
    v
Messages::VoicesController#create (inherits Messages::BaseController)
    |-- voice_audio already attached? -> return URL immediately (200)
    |-- otherwise -> enqueue GenerateVoiceJob, return 202
    |
    v
GenerateVoiceJob
    |-- Message::SpeechText strips markdown
    |-- ElevenLabsTts.synthesize(text, voice_id:)
    |-- attach result as message.voice_audio
    |-- save! triggers Broadcastable refresh
    |
    v
ActionCable broadcast -> Inertia reloads messages -> voice_audio_url populated -> AudioPlayer plays
```

## Implementation Plan

### Step 1: Database Migration

- [ ] Create migration `AddVoiceIdToAgents`

```ruby
class AddVoiceIdToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :voice_id, :string
  end
end
```

Only `voice_id`. No `voice_settings` column -- the `ElevenLabsTts` class carries sensible defaults. Per-agent tuning can be added in a future migration when actually needed.

**File**: `db/migrate/XXXXXXXXXX_add_voice_id_to_agents.rb`

---

### Step 2: Agent Model Changes

- [ ] Add `voiced?` method
- [ ] Add `voiced?` to `json_attributes`

```ruby
# app/models/agent.rb

json_attributes :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
                :summary_prompt,
                :model_id, :model_label, :enabled_tools, :active?, :colour, :icon,
                :memories_count, :memory_token_summary, :thinking_enabled, :thinking_budget,
                :telegram_bot_username, :telegram_configured?,
                :voiced?

def voiced?
  voice_id.present?
end
```

**File**: `/app/models/agent.rb`

---

### Step 3: Message Model Changes

- [ ] Add `has_one_attached :voice_audio`
- [ ] Add `voice_available` and `voice_audio_url` to `json_attributes`
- [ ] Add `content_for_speech` one-liner delegating to `Message::SpeechText`

```ruby
# app/models/message.rb

has_one_attached :voice_audio

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

def content_for_speech
  Message::SpeechText.new(content).to_s
end
```

The `voice_audio_url` method mirrors the existing `audio_url` method at line 200 of the same file.

**File**: `/app/models/message.rb`

---

### Step 4: Message::SpeechText Value Object

- [ ] Create `app/models/message/speech_text.rb`

A focused value object that encapsulates the markdown-to-speech stripping pipeline. Each transformation gets a named method instead of a comment. Keeps the 614-line Message model clean.

```ruby
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

  def strip_images
    @text.gsub!(/!\[[^\]]*\]\([^)]*\)/, "")
  end

  def strip_links
    @text.gsub!(/\[([^\]]*)\]\([^)]*\)/) { $1 }
  end

  def strip_urls
    @text.gsub!(%r{https?://\S+}, "")
  end

  def strip_stage_directions
    @text.gsub!(/^\s*\*[^*]+\*\s*$/m, "")
  end

  def strip_markdown_formatting
    @text.gsub!(/^#{1,6}\s+/, "")           # headings
    @text.gsub!(/\*\*([^*]+)\*\*/) { $1 }   # bold
    @text.gsub!(/\*([^*]+)\*/) { $1 }       # italic
    @text.gsub!(/~~([^~]+)~~/) { $1 }       # strikethrough
    @text.gsub!(/^[\s]*[-*+]\s+/, "")        # unordered list markers
    @text.gsub!(/^[\s]*\d+\.\s+/, "")        # ordered list markers
    @text.gsub!(/^>\s+/, "")                 # blockquotes
    @text.gsub!(/^---+$/, "")                # horizontal rules
  end

  def collapse_whitespace
    @text.gsub!(/\n{3,}/, "\n\n")
  end

end
```

ElevenLabs v3 tonal tags like `[whispers]`, `[excited]`, `[sarcastically]` are intentionally preserved -- none of the stripping rules match square-bracket directives.

**File**: `/app/models/message/speech_text.rb`

---

### Step 5: ElevenLabs TTS Library Class

- [ ] Create `lib/eleven_labs_tts.rb` mirroring `lib/eleven_labs_stt.rb`

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

  def self.synthesize(text, voice_id:)
    new.synthesize(text, voice_id: voice_id)
  end

  def synthesize(text, voice_id:)
    uri = URI("#{API_BASE}/#{voice_id}")

    request = Net::HTTP::Post.new(uri)
    request["xi-api-key"] = api_key
    request["Content-Type"] = "application/json"
    request["Accept"] = "audio/mpeg"

    request.body = {
      text: text,
      model_id: MODEL_ID,
      voice_settings: DEFAULT_VOICE_SETTINGS
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

Returns raw binary audio data (MP3 bytes). The job handles attaching it to Active Storage. No `voice_settings` parameter -- all agents use `DEFAULT_VOICE_SETTINGS` for now.

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

    text = message.content_for_speech
    return if text.blank?

    audio_data = ElevenLabsTts.synthesize(text, voice_id: message.agent.voice_id)

    message.voice_audio.attach(
      io: StringIO.new(audio_data),
      filename: "voice-#{message.to_param}.mp3",
      content_type: "audio/mpeg"
    )
  end

end
```

When `voice_audio.attach` saves the message, the existing `Broadcastable` concern fires `broadcast_refresh` via `after_commit`. Since `Message` already `broadcasts_to :chat`, the frontend's sync subscription on `Chat:#{chat.obfuscated_id}` triggers an Inertia reload of the messages prop, delivering `voice_audio_url` without any custom ActionCable wiring.

**File**: `/app/jobs/generate_voice_job.rb`

---

### Step 7: Messages::BaseController (DRY extraction)

- [ ] Create `Messages::BaseController` with shared authorization
- [ ] Refactor `RetriesController` and `HallucinationFixesController` to inherit from it

The `set_message_and_chat` method is currently duplicated across `RetriesController` and `HallucinationFixesController` with slight variation. Extract into a shared base class using the simpler `current_account` pattern (which `RetriesController` already uses successfully via `AccountScoping`).

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

Refactor existing controllers:

```ruby
# app/controllers/messages/retries_controller.rb
class Messages::RetriesController < Messages::BaseController

  before_action :require_respondable_chat

  def create
    AiResponseJob.perform_later(@chat)

    respond_to do |format|
      format.html { redirect_to account_chat_path(@chat.account, @chat) }
      format.json { head :ok }
    end
  rescue => e
    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Retry failed: #{e.message}" }
      format.json { head :internal_server_error }
    end
  end

  private

  def require_respondable_chat
    return if @chat.respondable?

    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "This conversation is archived or deleted and cannot receive new messages" }
      format.json { render json: { error: "This conversation is archived or deleted" }, status: :unprocessable_entity }
    end
  end

end
```

```ruby
# app/controllers/messages/hallucination_fixes_controller.rb
class Messages::HallucinationFixesController < Messages::BaseController

  def create
    @message.fix_hallucinated_tool_calls!
    redirect_to account_chat_path(@chat.account, @chat)
  rescue StandardError => e
    redirect_to account_chat_path(@chat.account, @chat), alert: "Failed to fix: #{e.message}"
  end

end
```

Both controllers drop their private `set_message_and_chat` methods and their `require_feature_enabled :chats` declarations -- inherited from the base.

**Files**:
- `/app/controllers/messages/base_controller.rb` (create)
- `/app/controllers/messages/retries_controller.rb` (modify)
- `/app/controllers/messages/hallucination_fixes_controller.rb` (modify)

---

### Step 8: VoicesController

- [ ] Create `Messages::VoicesController` inheriting from `Messages::BaseController`

```ruby
class Messages::VoicesController < Messages::BaseController

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

end
```

Response contract:
- **200** with `{ voice_audio_url: "..." }` -- audio cached, play immediately
- **202** with empty body -- job enqueued, wait for Broadcastable refresh
- **422** -- voice not available for this message

**File**: `/app/controllers/messages/voices_controller.rb`

---

### Step 9: Route

- [ ] Add the voice route nested under `resources :messages`

```ruby
# config/routes.rb -- inside the existing top-level messages block:

resources :messages, only: [ :update, :destroy ] do
  scope module: :messages do
    resource :retry, only: :create
    resource :hallucination_fix, only: :create
    resource :voice, only: :create
  end
end
```

Produces: `POST /messages/:message_id/voice` -> `Messages::VoicesController#create`

After adding the route, run `bin/rails js:routes:generate` to regenerate the JS routes file, producing `messageVoicePath(messageId)`.

**File**: `/config/routes.rb`

---

### Step 10: Frontend -- MessageBubble.svelte

- [ ] Add `SpeakerSimpleHigh` to the existing phosphor-svelte import
- [ ] Add `onvoice` callback prop
- [ ] Add voice controls outside `Card.Content`, after the metadata line, matching user audio placement

```svelte
<!-- Update the existing import at line 5 (add SpeakerSimpleHigh to it): -->
import { ArrowClockwise, Spinner, Globe, PencilSimple, SpeakerSimpleHigh, Trash, Wrench } from 'phosphor-svelte';

<!-- Add onvoice to the props destructuring: -->
let {
  message,
  isLastVisible = false,
  isGroupChat = false,
  showResend = false,
  streamingThinking = '',
  shikiTheme = 'catppuccin-latte',
  onedit,
  ondelete,
  onretry,
  onfix,
  onresend,
  onimagelightbox,
  onvoice,
} = $props();
```

Place voice controls after the agent message's metadata `<div>` (after line 213), outside the Card, mirroring how user audio is placed at lines 123-127:

```svelte
        <!-- existing metadata div ends at line 213 -->
        </div>
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
      </div>
    </div>
  {/if}
</div>
```

`_voice_loading` is a transient client-side flag set by the parent page. The underscore prefix signals it is not a server prop.

**File**: `/app/frontend/lib/components/chat/MessageBubble.svelte`

---

### Step 11: Frontend -- chats/show.svelte

- [ ] Add `updateMessage` helper to DRY up array-mapping
- [ ] Add `requestVoice` function using the helper
- [ ] Import `messageVoicePath` from routes
- [ ] Pass `onvoice` callback to MessageBubble

```javascript
// Add to route imports:
import {
  accountChatMessagesPath,
  messageRetryPath,
  accountChatAgentAssignmentPath,
  messagePath,
  messageHallucinationFixPath,
  accountChatParticipantPath,
  messageVoicePath,
} from '@/routes';

// Add helper function (near the other message manipulation functions):
function updateMessage(messageId, patch) {
  recentMessages = recentMessages.map((m) =>
    m.id === messageId ? { ...m, ...patch } : m
  );
}

// Add voice request function:
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

Pass the callback to MessageBubble:

```svelte
<MessageBubble
  {message}
  isLastVisible={index === visibleMessages.length - 1}
  isGroupChat={chat?.manual_responses}
  showResend={index === visibleMessages.length - 1 &&
    lastUserMessageNeedsResend &&
    !waitingForResponse &&
    !chat?.manual_responses}
  streamingThinking={streamingThinking[message.id] || ''}
  {shikiTheme}
  onedit={startEditingMessage}
  ondelete={deleteMessage}
  onretry={retryMessage}
  onfix={fixHallucinatedToolCalls}
  onresend={resendLastMessage}
  onimagelightbox={openImageLightbox}
  onvoice={requestVoice} />
```

When the background job completes, `voice_audio.attach` triggers `message.save!`, which fires `Broadcastable` `after_commit`. The Chat channel receives a refresh signal, the frontend's `createDynamicSync` subscription triggers an Inertia partial reload of `messages`, the reloaded message has `voice_audio_url` populated, and the `_voice_loading` flag is naturally cleared because the entire message object is replaced by fresh server data.

**File**: `/app/frontend/pages/chats/show.svelte`

---

### Step 12: System Prompt Update for Voiced Agents

- [ ] Add voice tag instructions to `Chat#system_message_for`

```ruby
# app/models/chat.rb -- inside system_message_for(agent, ...), before the timestamp line:

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

### Step 13: Seed Voice Data

- [ ] Set voice_id for the four agents via Rails console

One-time setup. No migration needed:

```ruby
account = Account.first

{ "Chris" => "JewcNslG8KqUpiFxGwfX",
  "Claude" => "H8WYgYgDseTlAoQnNEac",
  "Grok" => "vtcGSOQ5BUsEzdBNaKWo",
  "Wing" => "AWtKLCFhfixN68SjZWSo"
}.each do |name, voice_id|
  agent = account.agents.find_by!(name: name)
  agent.update!(voice_id: voice_id)
end
```

---

## File Summary

| # | File | Action | Description |
|---|------|--------|-------------|
| 1 | `db/migrate/XXXX_add_voice_id_to_agents.rb` | Create | Add `voice_id` column |
| 2 | `app/models/agent.rb` | Modify | Add `voiced?`, update `json_attributes` |
| 3 | `app/models/message.rb` | Modify | Add `voice_audio` attachment, `voice_available`, `voice_audio_url`, `content_for_speech` |
| 4 | `app/models/message/speech_text.rb` | Create | Markdown-to-speech stripping value object |
| 5 | `lib/eleven_labs_tts.rb` | Create | TTS API client, mirrors STT pattern |
| 6 | `app/jobs/generate_voice_job.rb` | Create | Calls TTS, attaches audio to message |
| 7 | `app/controllers/messages/base_controller.rb` | Create | Shared authorization for Messages:: controllers |
| 8 | `app/controllers/messages/retries_controller.rb` | Modify | Inherit from BaseController |
| 9 | `app/controllers/messages/hallucination_fixes_controller.rb` | Modify | Inherit from BaseController |
| 10 | `app/controllers/messages/voices_controller.rb` | Create | Voice endpoint |
| 11 | `config/routes.rb` | Modify | Add `resource :voice` under messages |
| 12 | `app/models/chat.rb` | Modify | Add voice tonal tag instructions to system prompt |
| 13 | `app/frontend/lib/components/chat/MessageBubble.svelte` | Modify | Add voice button + AudioPlayer for agent messages |
| 14 | `app/frontend/pages/chats/show.svelte` | Modify | Add `updateMessage` helper, `requestVoice`, `onvoice` callback |

---

## Testing Strategy

### Backend Tests

- [ ] **`test/models/message/speech_text_test.rb`** -- the value object is independently testable
  - Replaces fenced code blocks with spoken marker
  - Strips inline code backticks (keeps text)
  - Removes image markdown
  - Converts links to plain text
  - Removes raw URLs
  - Removes standalone action markers (`*sits with this*`)
  - Preserves emphasis within sentences (strips asterisks, keeps text)
  - Preserves ElevenLabs tonal tags (`[whispers]`, `[excited]`)
  - Strips heading markers, bold, italic, strikethrough, list markers, blockquotes, horizontal rules
  - Collapses multiple blank lines
  - Truncates to 5,000 characters
  - Returns empty string for blank content

- [ ] **`test/models/message_test.rb`** -- `voice_available`
  - Returns true for assistant messages with a voiced agent
  - Returns false for user messages
  - Returns false for assistant messages without a voiced agent
  - Returns false for system/tool messages

- [ ] **`test/models/agent_test.rb`** -- `voiced?`
  - Returns true when voice_id is present
  - Returns false when voice_id is blank/nil

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

- [ ] **MessageBubble** -- voice button appears only when `voice_available: true` and not streaming
- [ ] **MessageBubble** -- AudioPlayer renders when `voice_audio_url` is present
- [ ] **MessageBubble** -- no voice controls on user messages

---

## Edge Cases and Error Handling

1. **Empty content after stripping**: If `Message::SpeechText` returns blank (e.g., message was just a code block), the job silently skips. The loading state clears on the next Inertia refresh.

2. **ElevenLabs rate limiting**: The job retries 3 times with 5-second waits. If all attempts fail, the message simply won't have voice audio. The frontend loading state clears on Inertia refresh since `voice_audio_url` remains null.

3. **Very long messages**: Truncated to 5,000 characters (ElevenLabs v3 max). No error, just truncation.

4. **Concurrent requests**: If a user clicks play twice, the controller returns 202 both times. The job checks `message.voice_audio.attached?` at the start, preventing duplicate API calls.

5. **Message deleted before job runs**: `discard_on ActiveRecord::RecordNotFound` handles this cleanly.

6. **Agent voice_id removed after audio generated**: Cached audio remains playable. `voice_available` returns false so the button disappears for new messages, but existing attached audio still has a valid URL.

---

## External Dependencies

None. ElevenLabs API is already in use (for STT). No new gems or npm packages required.
