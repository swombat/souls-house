# Audio File Storage, Playback, and LLM Access

## Executive Summary

Voice recordings are currently discarded after transcription. This spec adds three capabilities:

1. **Storage** -- Save the original audio recording on S3 alongside the transcribed message, using a dedicated `has_one_attached :audio_recording` on Message.
2. **Playback UI** -- Show a small microphone icon on messages that originated as voice. Tapping/clicking reveals an inline mini-player (play/pause + progress bar) in the style of WhatsApp/Telegram.
3. **`FetchAudioTool`** -- A tool registered only for Gemini models that lets the agent retrieve the original audio file into its context by obfuscated message ID.

The transcript text remains the primary content for all models. Audio is supplementary context available only to models that can process it.

---

## Architecture Overview

### Data Flow

```
User taps mic
  -> MicButton records WebM/Opus blob
  -> POST /accounts/:id/chats/:id/transcription  (audio blob)
  -> TranscriptionsController:
       1. Transcribe via ElevenLabs  -> text
       2. Attach audio blob to a temp upload  -> signed_id
       3. Return { text, audio_signed_id }
  -> Frontend receives text + signed_id
  -> Frontend auto-sends message with audio_signed_id in form data
  -> MessagesController#create:
       1. Creates message with content = transcript text
       2. Attaches audio_recording from signed_id
       3. Sets audio_source: true flag
  -> Message stored with audio_recording in S3 + transcript in content
```

### Why `has_one_attached :audio_recording` (not reusing `:attachments`)

- **Semantic clarity**: Audio recordings are fundamentally different from user-uploaded file attachments. A voice message IS the message; an attachment accompanies it.
- **No variant pollution**: Audio recordings never need image variants (`:thumb`, `:preview`).
- **Simpler queries**: `message.audio_recording.attached?` is clearer than filtering `attachments` by content type plus an `audio_source` flag.
- **Display separation**: The audio player renders in a completely different location than file attachments (inline in the bubble vs. below content).
- **Future-proof**: If we add audio editing, transcription improvements, or audio processing, the dedicated attachment gives us a clean hook.

### Model ID to Audio Capability Mapping

Audio input support is tracked via a class method on Chat:

```ruby
# Models that can process audio input natively
AUDIO_INPUT_MODELS = %w[
  google/gemini-3-pro-preview
  google/gemini-3-flash-preview
  google/gemini-2.5-pro
  google/gemini-2.5-flash
].freeze

def self.supports_audio_input?(model_id)
  AUDIO_INPUT_MODELS.include?(model_id)
end
```

This is a simple constant -- no database table, no gem, no configuration. When new models gain audio support, add them to the list.

---

## Step-by-Step Implementation

### 1. Database Migration

- [ ] Generate migration: `rails g migration AddAudioSourceToMessages audio_source:boolean`

```ruby
class AddAudioSourceToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :audio_source, :boolean, default: false, null: false
  end
end
```

No index needed -- we never query by `audio_source` in isolation. ActiveStorage handles the `audio_recording` attachment via the existing `active_storage_attachments` and `active_storage_blobs` tables.

### 2. Message Model Updates

- [ ] Add `has_one_attached :audio_recording` to Message
- [ ] Add `audio_source` to `json_attributes`
- [ ] Add `audio_url` method for the frontend
- [ ] Add `audio/webm` to ACCEPTABLE_FILE_TYPES audio list

```ruby
class Message < ApplicationRecord
  # ... existing code ...

  has_one_attached :audio_recording

  ACCEPTABLE_FILE_TYPES = {
    # ... existing types ...
    audio: %w[audio/mpeg audio/wav audio/m4a audio/ogg audio/flac audio/webm],
    # ...
  }.freeze

  json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                  :completed, :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :content_html, :tools_used, :tool_status,
                  :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                  :editable, :deletable,
                  :moderation_flagged, :moderation_severity, :moderation_scores,
                  :fixable,
                  :audio_source, :audio_url

  def audio_url
    return unless audio_recording.attached?

    Rails.application.routes.url_helpers.rails_blob_url(audio_recording, only_path: true)
  rescue ArgumentError
    nil
  end

  def audio_path_for_llm
    return unless audio_recording.attached?

    blob = audio_recording.blob
    return unless blob.service.exist?(audio_recording.key)

    if blob.service.respond_to?(:path_for)
      blob.service.path_for(audio_recording.key)
    else
      tempfile = Tempfile.new(["audio", File.extname(audio_recording.filename.to_s)])
      tempfile.binmode
      audio_recording.download { |chunk| tempfile.write(chunk) }
      tempfile.rewind
      tempfile.path
    end
  rescue Errno::ENOENT, ActiveStorage::FileNotFoundError
    nil
  end
end
```

### 3. TranscriptionsController Changes

- [ ] After transcription, create a direct upload blob and return its `signed_id`
- [ ] Return both `text` and `audio_signed_id` in the response

```ruby
class Chats::TranscriptionsController < ApplicationController

  include ChatScoped

  before_action :require_respondable_chat

  def create
    audio = params.require(:audio)
    text = ElevenLabsStt.transcribe(audio)

    if text.present?
      blob = ActiveStorage::Blob.create_and_upload!(
        io: audio.tempfile,
        filename: audio.original_filename || "recording.webm",
        content_type: audio.content_type || "audio/webm"
      )

      render json: { text: text, audio_signed_id: blob.signed_id }
    else
      render json: { error: "No speech detected" }, status: :unprocessable_entity
    end
  rescue ElevenLabsStt::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

end
```

Key design decision: We create the blob in the transcription controller because this is where the audio file is available. The signed_id is a secure token that the frontend passes back when creating the message. This avoids a second upload of the same file.

### 4. MessagesController Changes

- [ ] Accept `audio_signed_id` parameter
- [ ] Attach audio recording and set `audio_source` flag when present

```ruby
class MessagesController < ApplicationController
  # ... existing code ...

  def create
    @message = @chat.messages.build(
      message_params.merge(user: Current.user, role: "user")
    )
    @message.attachments.attach(params[:files]) if params[:files].present?

    if params[:audio_signed_id].present?
      @message.audio_recording.attach(params[:audio_signed_id])
      @message.audio_source = true
    end

    if @message.save
      # ... existing success handling ...
    end
    # ... rest unchanged ...
  end

  private

  def message_params
    params.require(:message).permit(:content)
  end
end
```

Note: `audio_signed_id` is intentionally not in `message_params` -- it's a separate concern handled explicitly in the controller, not a message attribute coming from the form.

### 5. MicButton.svelte Changes

- [ ] Store `audio_signed_id` from transcription response
- [ ] Pass both text and signed_id to the success callback

```svelte
<script>
  // ... existing code ...

  let { disabled = false, accountId, chatId, onsuccess, onerror } = $props();

  // ... existing recording code unchanged ...

  async function transcribe(blob, mimeType) {
    state = 'transcribing';

    const ext = mimeType.includes('mp4') ? 'mp4' : 'webm';
    const formData = new FormData();
    formData.append('audio', blob, `recording.${ext}`);

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;

      const response = await fetch(`/accounts/${accountId}/chats/${chatId}/transcription`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          Accept: 'application/json',
        },
        body: formData,
      });

      const data = await response.json();

      if (response.ok && data.text) {
        onsuccess?.(data.text, data.audio_signed_id);
      } else {
        onerror?.(data.error || 'Transcription failed');
      }
    } catch (err) {
      onerror?.('Network error during transcription');
    } finally {
      state = 'idle';
    }
  }
</script>
```

### 6. show.svelte Changes (Message Sending)

- [ ] Update `handleTranscription` to accept and pass `audio_signed_id`
- [ ] Include `audio_signed_id` in message form data when present

```javascript
let pendingAudioSignedId = $state(null);

function handleTranscription(text, audioSignedId) {
  pendingAudioSignedId = audioSignedId || null;
  $messageForm.message.content = text;
  sendMessage();
}

function sendMessage() {
  // ... existing validation ...

  const formData = new FormData();
  formData.append('message[content]', $messageForm.message.content);
  selectedFiles.forEach((file) => formData.append('files[]', file));

  if (pendingAudioSignedId) {
    formData.append('audio_signed_id', pendingAudioSignedId);
  }

  // ... existing submit logic ...

  router.post(accountChatMessagesPath(account.id, chat.id), formData, {
    onSuccess: () => {
      // ... existing success handling ...
      pendingAudioSignedId = null;
    },
    onError: (errors) => {
      // ... existing error handling ...
      pendingAudioSignedId = null;
    },
  });
}
```

### 7. Audio Playback UI

- [ ] Create `AudioPlayer.svelte` component
- [ ] Add audio indicator icon to message bubbles
- [ ] Show/hide player on tap/click

#### AudioPlayer.svelte

```svelte
<script>
  import { Microphone, Play, Pause } from 'phosphor-svelte';

  let { src } = $props();

  let audioEl = $state(null);
  let playing = $state(false);
  let progress = $state(0);
  let duration = $state(0);
  let expanded = $state(false);

  function toggle() {
    if (!expanded) {
      expanded = true;
      return;
    }
    if (playing) {
      audioEl?.pause();
    } else {
      audioEl?.play();
    }
  }

  function handleTimeUpdate() {
    if (audioEl && duration > 0) {
      progress = (audioEl.currentTime / duration) * 100;
    }
  }

  function handleLoadedMetadata() {
    if (audioEl) {
      duration = audioEl.duration;
    }
  }

  function handleEnded() {
    playing = false;
    progress = 0;
  }

  function seek(e) {
    if (!audioEl || !duration) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const ratio = (e.clientX - rect.left) / rect.width;
    audioEl.currentTime = ratio * duration;
  }

  function formatTime(seconds) {
    if (!seconds || !isFinite(seconds)) return '0:00';
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, '0')}`;
  }
</script>

<div class="inline-flex items-center gap-2">
  <button
    type="button"
    onclick={toggle}
    class="inline-flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground transition-colors"
    title={expanded ? (playing ? 'Pause' : 'Play') : 'Play voice message'}>
    {#if expanded && playing}
      <Pause size={14} weight="fill" />
    {:else if expanded}
      <Play size={14} weight="fill" />
    {:else}
      <Microphone size={14} weight="fill" class="text-blue-500" />
    {/if}
  </button>

  {#if expanded}
    <div class="flex items-center gap-2 min-w-[120px]">
      <button
        type="button"
        onclick={seek}
        class="flex-1 h-1 bg-muted rounded-full cursor-pointer relative group">
        <div
          class="h-full bg-blue-500 rounded-full transition-all"
          style="width: {progress}%">
        </div>
        <div
          class="absolute top-1/2 -translate-y-1/2 w-2.5 h-2.5 bg-blue-500 rounded-full
                 opacity-0 group-hover:opacity-100 transition-opacity"
          style="left: {progress}%">
        </div>
      </button>
      <span class="text-[10px] text-muted-foreground tabular-nums w-8 text-right">
        {playing ? formatTime(audioEl?.currentTime) : formatTime(duration)}
      </span>
    </div>

    <audio
      bind:this={audioEl}
      {src}
      preload="metadata"
      onplay={() => (playing = true)}
      onpause={() => (playing = false)}
      ontimeupdate={handleTimeUpdate}
      onloadedmetadata={handleLoadedMetadata}
      onended={handleEnded}>
    </audio>
  {/if}
</div>
```

#### Message Bubble Integration

In `show.svelte`, add the audio indicator below the message timestamp for user messages:

```svelte
<!-- Inside user message bubble, after the timestamp div -->
{#if message.audio_source && message.audio_url}
  <div class="mt-1 flex justify-end">
    <AudioPlayer src={message.audio_url} />
  </div>
{/if}
```

The audio indicator appears as a small blue microphone icon below the message. Tapping it expands into the mini-player with play/pause and progress bar. This is unobtrusive -- the transcript text remains the primary display.

### 8. FetchAudioTool

- [ ] Create `app/tools/fetch_audio_tool.rb`
- [ ] Simple, non-polymorphic tool (single purpose, no actions pattern needed)
- [ ] Register only for agents using audio-capable models

```ruby
class FetchAudioTool < RubyLLM::Tool

  description "Fetch the original audio recording for a voice message. " \
              "Returns the audio file so you can hear the user's actual voice, tone, and inflection. " \
              "Use the message_id shown in the conversation context."

  param :message_id, type: :string,
        desc: "The obfuscated ID of the message with the audio recording",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(message_id:)
    return { error: "No chat context" } unless @chat

    message = @chat.messages.find_by(id: Message.decode_id(message_id))
    return { error: "Message not found in this conversation" } unless message
    return { error: "This message has no audio recording" } unless message.audio_recording.attached?

    audio_path = message.audio_path_for_llm
    return { error: "Audio file unavailable" } unless audio_path

    RubyLLM::Content.new(
      "Audio recording from #{message.author_name} at #{message.created_at_formatted}",
      [audio_path]
    )
  end

end
```

**Key design decisions:**

- Returns `RubyLLM::Content` with the audio file path, which ruby-llm handles natively as multimodal input.
- Scoped to `@chat.messages` so an agent can only access audio from the current conversation.
- Uses the existing `Message.decode_id` (ObfuscatesId) for secure message lookup.
- NOT a polymorphic/domain tool -- it has exactly one purpose. The actions pattern would add unnecessary complexity.

### 9. Audio-Aware Context in Chat Model

- [ ] Add `AUDIO_INPUT_MODELS` constant
- [ ] Add `supports_audio_input?` class method
- [ ] Include audio message IDs in context for audio-capable models
- [ ] Register FetchAudioTool conditionally

```ruby
class Chat < ApplicationRecord
  # ... existing code ...

  AUDIO_INPUT_MODELS = %w[
    google/gemini-3-pro-preview
    google/gemini-3-flash-preview
    google/gemini-2.5-pro
    google/gemini-2.5-flash
  ].freeze

  def self.supports_audio_input?(model_id)
    AUDIO_INPUT_MODELS.include?(model_id)
  end
end
```

#### Context annotation for audio messages

In the `format_message_for_context` method, annotate messages that have audio recordings with their obfuscated ID so the model knows which messages have audio available:

```ruby
def format_message_for_context(message, current_agent, timezone, thinking_enabled: false)
  timestamp = message.created_at.in_time_zone(timezone).strftime("[%Y-%m-%d %H:%M]")

  text_content = if message.agent_id == current_agent.id
    "#{timestamp} #{message.content}"
  elsif message.agent_id.present?
    "#{timestamp} [#{message.agent.name}]: #{message.content}"
  else
    name = message.user&.full_name.presence || message.user&.email_address&.split("@")&.first || "User"
    "#{timestamp} [#{name}]: #{message.content}"
  end

  # Annotate audio messages so models can use fetch_audio tool
  if message.audio_source? && message.audio_recording.attached?
    text_content += " [voice message, audio_id: #{message.obfuscated_id}]"
  end

  # ... rest unchanged ...
end
```

This annotation is lightweight (a few extra tokens) and only appears on voice messages. It gives the model enough information to call `fetch_audio` if it wants the original audio.

### 10. Tool Registration in ManualAgentResponseJob

- [ ] Conditionally add FetchAudioTool when the agent's model supports audio input AND there are audio messages in the chat

```ruby
# In ManualAgentResponseJob#perform, after existing tool setup:

# Add FetchAudioTool if the model supports audio input and there are voice messages
if Chat.supports_audio_input?(agent.model_id) && chat.messages.where(audio_source: true).exists?
  tool = FetchAudioTool.new(chat: chat, current_agent: agent)
  llm = llm.with_tool(tool)
  tools_added << "FetchAudioTool"
  debug_info "Added FetchAudioTool (model supports audio input, voice messages present)"
end
```

This is NOT added to the agent's `enabled_tools` configuration. It is automatically available whenever:
1. The agent's model supports audio input (currently Gemini models)
2. The conversation contains at least one voice message

This is analogous to how `WebTool` is automatically registered for chats with `web_access?` -- capability-driven, not configuration-driven.

### 11. Eager Loading Update

- [ ] Update `messages_page` to include `audio_recording_attachment`

```ruby
def messages_page(before_id: nil, limit: 30)
  scope = messages.includes(:user, :agent).with_attached_attachments.with_attached_audio_recording
  scope = scope.where("messages.id < ?", Message.decode_id(before_id)) if before_id.present?
  scope.reorder(id: :desc).limit(limit).reverse
end
```

Note: Rails 7+ supports `with_attached_<name>` for singular attachments. This avoids N+1 queries when rendering message JSON.

### 12. Fork Chat Update

- [ ] Copy `audio_recording` when forking chats

In `Chat#fork_with_title!`, after duplicating attachments:

```ruby
# Duplicate audio recording if present
if msg.audio_recording.attached?
  new_msg.audio_recording.attach(
    io: StringIO.new(msg.audio_recording.download),
    filename: msg.audio_recording.filename.to_s,
    content_type: msg.audio_recording.content_type
  )
  new_msg.update_column(:audio_source, true)
end
```

---

## Error Handling

### Transcription succeeds but blob creation fails
- The transcription controller wraps blob creation in the same request. If blob creation fails, the whole request returns an error. The frontend falls back to text-only mode (no audio_signed_id).

### Audio file missing from storage
- `audio_path_for_llm` checks `blob.service.exist?` before attempting access and returns nil if the file is gone.
- `audio_url` returns nil if the blob is missing (frontend simply doesn't show the player).
- FetchAudioTool returns a clear error message: "Audio file unavailable".

### Signed ID expired or invalid
- ActiveStorage raises `ActiveSupport::MessageVerifier::InvalidSignature` if a signed_id is tampered with or expired. The message is created without audio (graceful degradation).

### Browser doesn't support WebM playback (Safari < 17)
- Safari 17+ supports WebM/Opus playback natively. Older Safari versions cannot play WebM.
- The `<audio>` element handles this gracefully -- the player simply won't load. The transcript text is always available.
- Future enhancement: transcode to MP4/AAC for broader compatibility (out of scope for v1).

---

## Testing Strategy

### Model Tests (test/models/message_test.rb)

- [ ] `test "audio_source defaults to false"`
- [ ] `test "audio_url returns path when audio_recording attached"`
- [ ] `test "audio_url returns nil when no audio_recording"`
- [ ] `test "audio_path_for_llm returns local path for disk storage"`
- [ ] `test "as_json includes audio_source and audio_url"`

### Controller Tests

#### TranscriptionsController (test/controllers/chats/transcriptions_controller_test.rb)

- [ ] `test "returns audio_signed_id with successful transcription"`
- [ ] `test "audio_signed_id is a valid ActiveStorage signed id"`

#### MessagesController (test/controllers/messages_controller_test.rb)

- [ ] `test "creates message with audio_recording when audio_signed_id present"`
- [ ] `test "sets audio_source true when audio_signed_id present"`
- [ ] `test "creates normal message without audio when no audio_signed_id"`

### Tool Tests (test/tools/fetch_audio_tool_test.rb)

- [ ] `test "returns audio content for valid message with audio"`
- [ ] `test "returns error for message without audio"`
- [ ] `test "returns error for message not in chat"`
- [ ] `test "returns error for invalid message_id"`
- [ ] `test "scopes lookup to current chat"`

### Integration Tests

- [ ] `test "voice message flow: transcribe, send, display with audio indicator"`
- [ ] `test "forked chat preserves audio recordings"`

---

## Files to Create

| File | Purpose |
|------|---------|
| `db/migrate/XXXXXX_add_audio_source_to_messages.rb` | Migration |
| `app/tools/fetch_audio_tool.rb` | LLM audio access tool |
| `app/frontend/lib/components/chat/AudioPlayer.svelte` | Mini audio player |
| `test/tools/fetch_audio_tool_test.rb` | Tool tests |

## Files to Modify

| File | Changes |
|------|---------|
| `app/models/message.rb` | Add `has_one_attached :audio_recording`, `audio_url`, `audio_path_for_llm`, `audio_source` to json_attributes, `audio/webm` to acceptable types |
| `app/models/chat.rb` | Add `AUDIO_INPUT_MODELS`, `supports_audio_input?`, annotate audio messages in context |
| `app/controllers/chats/transcriptions_controller.rb` | Create blob, return `audio_signed_id` |
| `app/controllers/messages_controller.rb` | Accept `audio_signed_id`, attach audio recording |
| `app/jobs/manual_agent_response_job.rb` | Conditionally register FetchAudioTool |
| `app/frontend/lib/components/chat/MicButton.svelte` | Pass `audio_signed_id` through onsuccess callback |
| `app/frontend/pages/chats/show.svelte` | Handle `audio_signed_id` in form submission, render AudioPlayer |
| `test/controllers/chats/transcriptions_controller_test.rb` | Add audio_signed_id assertions |
| `test/controllers/messages_controller_test.rb` | Add audio message tests |

## No External Dependencies

This implementation uses only what is already in the stack:
- **ActiveStorage** for file storage (already configured with S3)
- **RubyLLM** for multimodal content (already supports audio)
- **Phosphor Icons** for the microphone/play/pause icons (already in the project)
- **HTML5 `<audio>` element** for playback (no JavaScript audio library needed)
