# Audio File Storage, Playback, and LLM Access (v3 -- Final)

## Executive Summary

Voice recordings are currently discarded after transcription. This spec adds three capabilities:

1. **Storage** -- Save the original audio recording on S3 alongside the transcribed message, using a dedicated `has_one_attached :audio_recording` on Message.
2. **Playback UI** -- Show an inline mini-player (play/pause + progress bar + duration) on messages that originated as voice, in the style of WhatsApp/Telegram.
3. **FetchAudioTool** -- A tool registered for audio-capable models (currently Gemini) in both `AiResponseJob` and `ManualAgentResponseJob` that lets the agent retrieve the original audio file into its context by obfuscated message ID.

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
       2. Create ActiveStorage blob  -> signed_id
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

### Audio Capability in MODELS Config

Audio input support is tracked via the existing `MODELS` config hash on Chat, following the same pattern as `thinking`. Each model that supports native audio input gets an `audio_input: true` key:

```ruby
{
  model_id: "google/gemini-3-pro-preview",
  label: "Gemini 3 Pro",
  group: "Top Models",
  thinking: { supported: true },
  audio_input: true
},
```

This follows the established convention -- one constant, one pattern. When someone adds a new model to `MODELS`, all capabilities are declared in one place. No disconnected constants to keep in sync.

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
- [ ] Add `audio_source`, `audio_url` to `json_attributes`
- [ ] Add `audio_url` method for the frontend
- [ ] Add `audio/webm` to ACCEPTABLE_FILE_TYPES audio list
- [ ] Extract shared `resolve_attachment_path` private method (placed in the existing private section, not a second `private` keyword)
- [ ] Refactor `file_paths_for_llm` to use `resolve_attachment_path`
- [ ] Add `audio_path_for_llm` using `resolve_attachment_path`

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

  def file_paths_for_llm
    return [] unless attachments.attached?

    attachments.filter_map { |file| resolve_attachment_path(file) }
  end

  def audio_path_for_llm
    resolve_attachment_path(audio_recording)
  end

  # ... existing public methods ...

  private

  # ... existing private methods ...

  # Place resolve_attachment_path in the existing private section of message.rb
  # (after the existing private methods like acceptable_files, render_markdown, etc.)
  # Do NOT introduce a second `private` keyword.
  def resolve_attachment_path(attachment)
    return unless attachment.attached?

    blob = attachment.blob
    return unless blob.service.exist?(attachment.key)

    if blob.service.respond_to?(:path_for)
      blob.service.path_for(attachment.key)
    else
      tempfile = Tempfile.new(["attachment", File.extname(attachment.filename.to_s)])
      tempfile.binmode
      attachment.download { |chunk| tempfile.write(chunk) }
      tempfile.rewind
      tempfile.path
    end
  rescue Errno::ENOENT, ActiveStorage::FileNotFoundError
    nil
  end
end
```

This eliminates the DRY violation between `file_paths_for_llm` and the new `audio_path_for_llm`. Both methods become trivially simple delegations to `resolve_attachment_path`, and the error handling lives in one place.

The `audio_url` method uses `rails_blob_url(audio_recording, only_path: true)` to match the established codebase convention in `message.rb` (line 180) and `profile.rb` (line 56).

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
- [ ] Add explicit `InvalidSignature` rescue for graceful degradation

```ruby
class MessagesController < ApplicationController
  # ... existing code ...

  def create
    @message = @chat.messages.build(
      message_params.merge(user: Current.user, role: "user")
    )
    @message.attachments.attach(params[:files]) if params[:files].present?

    if params[:audio_signed_id].present?
      begin
        @message.audio_recording.attach(params[:audio_signed_id])
        @message.audio_source = true
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        Rails.logger.warn "Invalid audio_signed_id for message in chat #{@chat.id}"
      end
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

Notes:
- `audio_signed_id` is intentionally not in `message_params` -- it is a separate concern handled explicitly in the controller, not a message attribute coming from the form.
- The `InvalidSignature` rescue makes graceful degradation explicit. If the signed_id is expired or tampered with, the message is created without audio rather than relying on the catch-all `rescue StandardError`.

### 5. MicButton.svelte Changes

- [ ] Pass `audio_signed_id` from transcription response through the `onsuccess` callback

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
// pendingAudioSignedId is safe from leaking into subsequent messages because
// handleTranscription calls sendMessage() synchronously, and the submitting
// guard prevents any second sendMessage() call until onSuccess/onError clears it.
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
- [ ] Add audio player to user message bubbles

#### AudioPlayer.svelte

The player always shows its controls (play/pause + progress bar + duration). One tap to play. No expand/collapse state -- this removes unnecessary interaction cost. The microphone icon that previously indicated "this is a voice message" is replaced by the always-visible player itself, which communicates the same thing more clearly.

The seek handle is shown at reduced opacity (50%) by default, increasing to full opacity on hover. This ensures touch device users can see the handle position (since `:hover` does not exist on touch devices), while desktop users get the same hover-to-highlight behavior.

```svelte
<script>
  import { Play, Pause } from 'phosphor-svelte';

  let { src } = $props();

  let audioEl = $state(null);
  let playing = $state(false);
  let progress = $state(0);
  let duration = $state(0);

  function toggle() {
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
    title={playing ? 'Pause' : 'Play voice message'}>
    {#if playing}
      <Pause size={14} weight="fill" />
    {:else}
      <Play size={14} weight="fill" />
    {/if}
  </button>

  <button
    type="button"
    onclick={seek}
    class="flex-1 h-1 bg-muted rounded-full cursor-pointer relative group min-w-[100px]">
    <div
      class="h-full bg-blue-500 rounded-full transition-all"
      style="width: {progress}%">
    </div>
    <div
      class="absolute top-1/2 -translate-y-1/2 w-2.5 h-2.5 bg-blue-500 rounded-full
             opacity-50 group-hover:opacity-100 transition-opacity"
      style="left: {progress}%">
    </div>
  </button>

  <span class="text-[10px] text-muted-foreground tabular-nums w-8 text-right">
    {playing ? formatTime(audioEl?.currentTime) : formatTime(duration)}
  </span>

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
</div>
```

#### Message Bubble Integration

In `show.svelte`, add the audio player below the message timestamp for user messages:

```svelte
<!-- Inside user message bubble, after the timestamp div -->
{#if message.audio_source && message.audio_url}
  <div class="mt-1 flex justify-end">
    <AudioPlayer src={message.audio_url} />
  </div>
{/if}
```

The player is small (14px icons and a thin progress bar) and unobtrusive. The transcript text remains the primary display.

### 8. Chat Model Changes

- [ ] Add `audio_input: true` to relevant model configs in `MODELS`
- [ ] Add `supports_audio_input?` class method following the `supports_thinking?` pattern
- [ ] Gate audio context annotation on model capability via `audio_tools_enabled` parameter
- [ ] Update `messages_context_for` to accept and pass `audio_tools_enabled`
- [ ] Update `build_context_for_agent` to compute and pass `audio_tools_enabled`

#### MODELS config additions

```ruby
MODELS = [
  {
    model_id: "google/gemini-3-pro-preview",
    label: "Gemini 3 Pro",
    group: "Top Models",
    thinking: { supported: true },
    audio_input: true
  },
  # ...
  { model_id: "google/gemini-3-flash-preview", label: "Gemini 3 Flash", group: "Google", audio_input: true },
  { model_id: "google/gemini-2.5-pro", label: "Gemini 2.5 Pro", group: "Google", audio_input: true },
  { model_id: "google/gemini-2.5-flash", label: "Gemini 2.5 Flash", group: "Google", audio_input: true },
  # ... all other models unchanged (no audio_input key) ...
].freeze
```

#### Class method

```ruby
def self.supports_audio_input?(model_id)
  model_config(model_id)&.dig(:audio_input) == true
end
```

This follows the exact same pattern as `supports_thinking?`. One constant, one pattern, no divergence.

#### Context annotation gated on model capability

The `[voice message, audio_id: ...]` annotation is only useful when the model has the FetchAudioTool available. For non-audio-capable models, it is wasted tokens that the model cannot act on.

```ruby
def build_context_for_agent(agent, thinking_enabled: false, initiation_reason: nil)
  audio_enabled = self.class.supports_audio_input?(agent.model_id) &&
                  messages.where(audio_source: true).exists?

  [system_message_for(agent, initiation_reason: initiation_reason)] +
    messages_context_for(agent, thinking_enabled: thinking_enabled, audio_tools_enabled: audio_enabled)
end

def messages_context_for(agent, thinking_enabled: false, audio_tools_enabled: false)
  tz = user_timezone
  messages.includes(:user, :agent).order(:created_at)
    .reject { |msg| msg.content.blank? }
    .reject { |msg| msg.used_tools? && msg.agent_id != agent.id }
    .map { |msg| format_message_for_context(msg, agent, tz, thinking_enabled: thinking_enabled, audio_tools_enabled: audio_tools_enabled) }
end

def format_message_for_context(message, current_agent, timezone, thinking_enabled: false, audio_tools_enabled: false)
  # ... existing timestamp and text_content logic unchanged ...

  if audio_tools_enabled && message.audio_source? && message.audio_recording.attached?
    text_content += " [voice message, audio_id: #{message.obfuscated_id}]"
  end

  # ... rest unchanged ...
end
```

### 9. FetchAudioTool

- [ ] Create `app/tools/fetch_audio_tool.rb`
- [ ] Simple, non-polymorphic tool (single purpose, no actions pattern needed)

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

Key design decisions:

- Returns `RubyLLM::Content` with the audio file path, which ruby_llm handles natively as multimodal input.
- Scoped to `@chat.messages` so an agent can only access audio from the current conversation.
- Uses the existing `Message.decode_id` (ObfuscatesId) for secure message lookup.
- NOT a polymorphic/domain tool -- it has exactly one purpose. The actions pattern would add unnecessary complexity.

### 10. Tool Registration in AiResponseJob

- [ ] Conditionally add FetchAudioTool when the chat's model supports audio input AND there are audio messages

This is the most critical registration point. `AiResponseJob` handles regular (non-manual) single-agent chats. Without this, a user chatting with Gemini in a regular chat would never have FetchAudioTool available.

`AiResponseJob` currently registers tools via `chat.available_tools`, which returns class references (not instances). However, FetchAudioTool requires `chat:` context for scoped message lookup, so it cannot be returned from `available_tools` as a bare class. Instead, we register it explicitly after the existing tool loop:

```ruby
class AiResponseJob < ApplicationJob

  include StreamsAiResponse

  # ... existing retry_on declarations ...

  def perform(chat)
    unless chat.is_a?(Chat)
      raise ArgumentError, "Expected a Chat object, got #{chat.class}: #{chat.inspect}"
    end

    @chat = chat
    @ai_message = nil
    setup_streaming_state

    chat.available_tools.each { |tool| chat = chat.with_tool(tool) }

    if Chat.supports_audio_input?(chat.model_id) && chat.messages.where(audio_source: true).exists?
      chat = chat.with_tool(FetchAudioTool.new(chat: chat))
    end

    chat.on_new_message do
      @ai_message = chat.messages.order(:created_at).last
      @ai_message.update!(streaming: true) if @ai_message
    end

    # ... rest unchanged ...
  end

  # ... rest unchanged ...
end
```

Note: In `AiResponseJob`, the `chat` variable is a `Chat` model that also acts as an LLM chat via `acts_as_chat`. The `with_tool` call adds the tool to the LLM session, not to the database model. The FetchAudioTool is instantiated with `chat:` for message scoping but without `current_agent:` (since regular chats do not have an explicit agent).

### 11. Tool Registration in ManualAgentResponseJob

- [ ] Conditionally add FetchAudioTool when the agent's model supports audio input AND there are audio messages in the chat

```ruby
# In ManualAgentResponseJob#perform, after existing tool setup:

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

### 12. Tool Registration in AllAgentsResponseJob

- [ ] Add the same FetchAudioTool registration pattern as ManualAgentResponseJob

```ruby
# In AllAgentsResponseJob#perform, after existing tool setup:

if Chat.supports_audio_input?(agent.model_id) && chat.messages.where(audio_source: true).exists?
  tool = FetchAudioTool.new(chat: chat, current_agent: agent)
  llm = llm.with_tool(tool)
  tools_added << "FetchAudioTool"
  debug_info "Added FetchAudioTool (model supports audio input, voice messages present)"
end
```

`AllAgentsResponseJob` mirrors `ManualAgentResponseJob`'s tool setup pattern (lines 69-74), so the FetchAudioTool registration goes in the same location.

### 13. Eager Loading Update

- [ ] Update `messages_page` to include `audio_recording_attachment`

```ruby
def messages_page(before_id: nil, limit: 30)
  scope = messages.includes(:user, :agent).with_attached_attachments.with_attached_audio_recording
  scope = scope.where("messages.id < ?", Message.decode_id(before_id)) if before_id.present?
  scope.reorder(id: :desc).limit(limit).reverse
end
```

Rails 7+ supports `with_attached_<name>` for singular attachments. This avoids N+1 queries when rendering message JSON.

### 14. Fork Chat Update

- [ ] Copy `audio_recording` when forking chats by reusing the blob reference

```ruby
# In Chat#fork_with_title!, after duplicating regular attachments:

if msg.audio_recording.attached?
  new_msg.audio_recording.attach(msg.audio_recording.blob)
  new_msg.update_column(:audio_source, true)
end
```

This creates a new attachment record pointing to the same blob. No download, no re-upload, instant. For audio recordings (which are larger than typical text files), the difference is meaningful compared to downloading and re-uploading via `StringIO`.

One caveat: if we later want to allow deleting audio from one fork without affecting the other, blob sharing would be a problem. But that is a YAGNI concern.

### 15. `create_with_message!` -- No Changes Needed

The `Chat.create_with_message!` method is only called from `ChatsController#create` when creating a new chat. Voice messages only enter through the existing chat flow (MicButton -> TranscriptionsController -> MessagesController#create on an existing chat). A user cannot record a voice message on the new-chat form since the MicButton requires an existing `chatId`. No changes are needed.

---

## Error Handling

### Transcription succeeds but blob creation fails
- The transcription controller wraps blob creation in the same request. If blob creation fails, the whole request returns an error. The frontend falls back to text-only mode (no audio_signed_id).

### Audio file missing from storage
- `resolve_attachment_path` checks `blob.service.exist?` before attempting access and returns nil if the file is gone.
- `audio_url` returns nil if the blob is missing (frontend simply does not show the player).
- FetchAudioTool returns a clear error message: "Audio file unavailable".

### Signed ID expired or invalid
- `ActiveSupport::MessageVerifier::InvalidSignature` is explicitly rescued in MessagesController. The message is created without audio, and a warning is logged. This is explicit graceful degradation, not a side effect of the catch-all `rescue StandardError`.

### Browser doesn't support WebM playback (Safari < 17)
- Safari 17+ supports WebM/Opus playback natively. Older Safari versions cannot play WebM.
- The `<audio>` element handles this gracefully -- the player simply will not load. The transcript text is always available.
- Future enhancement: transcode to MP4/AAC for broader compatibility (out of scope for v1).

---

## Testing Strategy

### Model Tests (test/models/message_test.rb)

- [ ] `test "audio_source defaults to false"`
- [ ] `test "audio_url returns path when audio_recording attached"`
- [ ] `test "audio_url returns nil when no audio_recording"`
- [ ] `test "audio_path_for_llm returns local path for disk storage"`
- [ ] `test "audio_path_for_llm returns nil when no audio_recording"`
- [ ] `test "file_paths_for_llm returns empty array when no attachments"`
- [ ] `test "as_json includes audio_source and audio_url"`

### Chat Model Tests (test/models/chat_test.rb)

- [ ] `test "supports_audio_input? returns true for Gemini models"`
- [ ] `test "supports_audio_input? returns false for non-Gemini models"`
- [ ] `test "audio annotation only added when audio_tools_enabled"`
- [ ] `test "audio annotation omitted when audio_tools_enabled is false"`

### Controller Tests

#### TranscriptionsController (test/controllers/chats/transcriptions_controller_test.rb)

- [ ] `test "returns audio_signed_id with successful transcription"`
- [ ] `test "audio_signed_id is a valid ActiveStorage signed id"`

#### MessagesController (test/controllers/messages_controller_test.rb)

- [ ] `test "creates message with audio_recording when audio_signed_id present"`
- [ ] `test "sets audio_source true when audio_signed_id present"`
- [ ] `test "creates normal message without audio when no audio_signed_id"`
- [ ] `test "handles invalid audio_signed_id gracefully"`

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
| `app/models/message.rb` | Add `has_one_attached :audio_recording`, `audio_url`, extract `resolve_attachment_path` into existing private section, refactor `file_paths_for_llm`, add `audio_path_for_llm`, `audio_source` + `audio_url` to json_attributes, `audio/webm` to acceptable types |
| `app/models/chat.rb` | Add `audio_input: true` to Gemini model configs, `supports_audio_input?` class method, gate audio annotation on `audio_tools_enabled` parameter in context methods |
| `app/controllers/chats/transcriptions_controller.rb` | Create blob, return `audio_signed_id` |
| `app/controllers/messages_controller.rb` | Accept `audio_signed_id`, attach audio recording, rescue `InvalidSignature` |
| `app/jobs/ai_response_job.rb` | Conditionally register FetchAudioTool for audio-capable models |
| `app/jobs/manual_agent_response_job.rb` | Conditionally register FetchAudioTool |
| `app/jobs/all_agents_response_job.rb` | Conditionally register FetchAudioTool |
| `app/frontend/lib/components/chat/MicButton.svelte` | Pass `audio_signed_id` through onsuccess callback |
| `app/frontend/pages/chats/show.svelte` | Handle `audio_signed_id` in form submission, render AudioPlayer, add safety comment |
| `test/controllers/chats/transcriptions_controller_test.rb` | Add audio_signed_id assertions |
| `test/controllers/messages_controller_test.rb` | Add audio message tests |
| `test/models/message_test.rb` | Add audio_path_for_llm and audio tests |
| `test/models/chat_test.rb` | Add supports_audio_input? and annotation gating tests |

## No External Dependencies

This implementation uses only what is already in the stack:
- **ActiveStorage** for file storage (already configured with S3)
- **RubyLLM** for multimodal content (already supports audio)
- **Phosphor Icons** for the play/pause icons (already in the project)
- **HTML5 `<audio>` element** for playback (no JavaScript audio library needed)
