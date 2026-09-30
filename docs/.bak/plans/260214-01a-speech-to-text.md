# Speech-to-Text Integration

**Date**: 2026-02-14
**Status**: Draft

---

## Executive Summary

Add a microphone button to the chat input area that lets users record audio, uploads it to Rails, which proxies to the ElevenLabs Scribe v2 batch API for transcription. The transcribed text is auto-sent as a message with no review step. Tap once to start recording, tap again to stop. Works on both desktop and mobile.

No new gems. No new npm packages. The browser's MediaRecorder API handles recording. Ruby's `Net::HTTP` handles the ElevenLabs API call (matching the existing pattern used by OuraApi, GithubApi, and WebTool). A single new controller endpoint receives the audio blob, transcribes it, and returns the text.

---

## Architecture Overview

```
User taps mic → MediaRecorder captures audio (WebM/Opus)
User taps mic again → Recording stops
                     → Audio blob uploaded via fetch() to Rails
                     → Rails proxies to ElevenLabs batch API
                     → Returns { text: "..." }
                     → Frontend calls sendMessage() with transcribed text
```

Three changes:
1. **New Svelte component**: `MicButton.svelte` -- recording toggle with visual feedback
2. **New Rails controller**: `Chats::TranscriptionsController` -- receives audio, calls ElevenLabs, returns text
3. **Modified file**: `show.svelte` -- add MicButton next to the existing Send button

---

## Step-by-Step Implementation

### Step 1: API Key in Rails Credentials

- [ ] Add ElevenLabs API key to Rails credentials

```bash
bin/rails credentials:edit
```

Add under the existing `ai:` namespace:

```yaml
ai:
  elevenlabs:
    api_key: "xi_..."
```

### Step 2: Route

- [ ] Add transcription route nested under chats

**File: `/Users/danieltenner/dev/helix_kit/config/routes.rb`**

Add inside the existing `resources :chats` block, within the `scope module: :chats` block:

```ruby
resources :chats do
  scope module: :chats do
    # ... existing routes ...
    resource :transcription, only: :create
  end
  resources :messages, only: [ :index, :create ]
end
```

This produces: `POST /accounts/:account_id/chats/:chat_id/transcription`

### Step 3: Transcription Controller

- [ ] Create `Chats::TranscriptionsController`

**File: `/Users/danieltenner/dev/helix_kit/app/controllers/chats/transcriptions_controller.rb`**

```ruby
class Chats::TranscriptionsController < ApplicationController

  include ChatScoped

  before_action :require_respondable_chat

  def create
    audio = params.require(:audio)
    text = ElevenLabsStt.transcribe(audio)

    if text.present?
      render json: { text: text }
    else
      render json: { error: "No speech detected" }, status: :unprocessable_entity
    end
  rescue ElevenLabsStt::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def require_respondable_chat
    return if @chat.respondable?

    render json: { error: "This conversation is archived or deleted" }, status: :unprocessable_entity
  end

end
```

Skinny controller. All ElevenLabs logic lives in the model-layer class. The `ChatScoped` concern handles authorization (same pattern as ForksController, ModerationsController, etc.).

### Step 4: ElevenLabs STT Service Class

- [ ] Create `ElevenLabsStt` in `app/models/`

**File: `/Users/danieltenner/dev/helix_kit/app/models/elevenlabs_stt.rb`**

This is a plain Ruby class that wraps the ElevenLabs batch API. It lives in `app/models/` because it encapsulates business logic (following the project convention of no service objects -- the architecture doc says "avoid service objects and premature optimization"). It is a simple class, not an ActiveRecord model.

```ruby
require "net/http"
require "json"

class ElevenLabsStt

  class Error < StandardError; end

  API_URL = "https://api.elevenlabs.io/v1/speech-to-text"
  MODEL_ID = "scribe_v2"

  def self.transcribe(audio_file)
    new.transcribe(audio_file)
  end

  def transcribe(audio_file)
    uri = URI(API_URL)
    boundary = SecureRandom.hex(16)

    body = build_multipart_body(audio_file, boundary)

    request = Net::HTTP::Post.new(uri)
    request["xi-api-key"] = api_key
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = body

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      read_timeout: 60, open_timeout: 10) { |http| http.request(request) }

    handle_response(response)
  end

  private

  def api_key
    Rails.application.credentials.dig(:ai, :elevenlabs, :api_key) ||
      ENV["ELEVENLABS_API_KEY"] ||
      raise(Error, "ElevenLabs API key not configured")
  end

  def build_multipart_body(audio_file, boundary)
    parts = []

    parts << "--#{boundary}\r\n" \
             "Content-Disposition: form-data; name=\"model_id\"\r\n\r\n" \
             "#{MODEL_ID}\r\n"

    parts << "--#{boundary}\r\n" \
             "Content-Disposition: form-data; name=\"tag_audio_events\"\r\n\r\n" \
             "false\r\n"

    parts << "--#{boundary}\r\n" \
             "Content-Disposition: form-data; name=\"timestamps_granularity\"\r\n\r\n" \
             "none\r\n"

    filename = audio_file.respond_to?(:original_filename) ? audio_file.original_filename : "audio.webm"
    content_type = audio_file.respond_to?(:content_type) ? audio_file.content_type : "audio/webm"

    parts << "--#{boundary}\r\n" \
             "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n" \
             "Content-Type: #{content_type}\r\n\r\n" \
             "#{audio_file.read}\r\n"

    parts << "--#{boundary}--\r\n"
    parts.join
  end

  def handle_response(response)
    case response.code.to_i
    when 200
      data = JSON.parse(response.body)
      text = data["text"]&.strip
      text.presence
    when 401
      raise Error, "Invalid ElevenLabs API key"
    when 429
      raise Error, "ElevenLabs rate limit exceeded. Please try again later."
    when 422
      error_msg = JSON.parse(response.body).dig("error", "message") rescue "Invalid request"
      raise Error, "Transcription failed: #{error_msg}"
    else
      Rails.logger.error("ElevenLabs STT error: #{response.code} - #{response.body}")
      raise Error, "Transcription service unavailable. Please try again."
    end
  end

end
```

Key design decisions:
- `tag_audio_events: false` -- we don't want "(laughter)" in chat messages
- `timestamps_granularity: none` -- we only need the text, not word timing
- Language detection is automatic (no `language_code` parameter)
- 60-second read timeout handles longer audio clips
- Class method `ElevenLabsStt.transcribe(file)` for ergonomic one-liner calls

### Step 5: MicButton Svelte Component

- [ ] Create `MicButton.svelte`

**File: `/Users/danieltenner/dev/helix_kit/app/frontend/lib/components/chat/MicButton.svelte`**

```svelte
<script>
  import { Microphone, MicrophoneSlash, Spinner } from 'phosphor-svelte';

  let {
    disabled = false,
    accountId,
    chatId,
    onsuccess,
    onerror,
  } = $props();

  let state = $state('idle');
  let mediaRecorder = $state(null);
  let audioChunks = $state([]);

  const isRecording = $derived(state === 'recording');
  const isTranscribing = $derived(state === 'transcribing');
  const isBusy = $derived(state !== 'idle');

  async function toggleRecording() {
    if (isRecording) {
      stopRecording();
    } else if (state === 'idle') {
      await startRecording();
    }
  }

  async function startRecording() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });

      const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
        ? 'audio/webm;codecs=opus'
        : MediaRecorder.isTypeSupported('audio/webm')
          ? 'audio/webm'
          : MediaRecorder.isTypeSupported('audio/mp4')
            ? 'audio/mp4'
            : '';

      const options = mimeType ? { mimeType } : {};
      const recorder = new MediaRecorder(stream, options);
      audioChunks = [];

      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) {
          audioChunks.push(event.data);
        }
      };

      recorder.onstop = async () => {
        stream.getTracks().forEach((track) => track.stop());

        if (audioChunks.length === 0) {
          state = 'idle';
          return;
        }

        const actualMimeType = recorder.mimeType || 'audio/webm';
        const blob = new Blob(audioChunks, { type: actualMimeType });
        audioChunks = [];

        if (blob.size < 1000) {
          state = 'idle';
          onerror?.('Recording too short');
          return;
        }

        await transcribe(blob, actualMimeType);
      };

      recorder.start();
      mediaRecorder = recorder;
      state = 'recording';
    } catch (err) {
      state = 'idle';
      if (err.name === 'NotAllowedError') {
        onerror?.('Microphone access denied. Please allow microphone access in your browser settings.');
      } else if (err.name === 'NotFoundError') {
        onerror?.('No microphone found. Please connect a microphone and try again.');
      } else {
        onerror?.('Could not start recording');
      }
    }
  }

  function stopRecording() {
    if (mediaRecorder && mediaRecorder.state === 'recording') {
      mediaRecorder.stop();
      state = 'transcribing';
    }
  }

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
        onsuccess?.(data.text);
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

<button
  type="button"
  onclick={toggleRecording}
  disabled={disabled || isTranscribing}
  class="h-10 w-10 p-0 inline-flex items-center justify-center rounded-md transition-colors
         {isRecording
    ? 'bg-red-500 text-white hover:bg-red-600 animate-pulse'
    : 'hover:bg-accent hover:text-accent-foreground'}
         disabled:pointer-events-none disabled:opacity-50"
  title={isRecording ? 'Stop recording' : isTranscribing ? 'Transcribing...' : 'Record voice message'}>
  {#if isTranscribing}
    <Spinner size={18} class="animate-spin" />
  {:else if isRecording}
    <MicrophoneSlash size={18} />
  {:else}
    <Microphone size={18} />
  {/if}
</button>
```

Design notes:
- Three states: `idle`, `recording`, `transcribing`
- Recording state: pulsing red button with MicrophoneSlash icon (visual cue that tapping stops)
- Transcribing state: spinning Spinner (same pattern as Send button when submitting)
- Uses `fetch()` instead of Inertia `router.post()` because this is a JSON API call, not a page navigation
- MIME type negotiation: prefers `audio/webm;codecs=opus` (Chrome/Firefox), falls back to `audio/mp4` (Safari), then default
- Minimum blob size check (1000 bytes) prevents accidental taps from sending empty audio
- Callback props `onsuccess` and `onerror` keep the component decoupled from the message-sending logic

### Step 6: Integrate MicButton into Chat Interface

- [ ] Modify `show.svelte` to include MicButton

**File: `/Users/danieltenner/dev/helix_kit/app/frontend/pages/chats/show.svelte`**

Add import (around line 36, with other chat component imports):

```svelte
import MicButton from '$lib/components/chat/MicButton.svelte';
```

Add handler function (near the `sendMessage` function, around line 692):

```svelte
function handleTranscription(text) {
  $messageForm.message.content = text;
  sendMessage();
}

function handleTranscriptionError(message) {
  errorMessage = message;
  setTimeout(() => (errorMessage = null), 5000);
}
```

Modify the message input area (around line 1641). Add `MicButton` between the textarea and the Send button:

```svelte
<!-- Message input -->
<div class="border-t border-border bg-muted/30 p-3 md:p-4">
  <div class="flex gap-2 md:gap-3 items-start">
    <FileUploadInput
      bind:files={selectedFiles}
      disabled={submitting || !chat?.respondable}
      allowedTypes={file_upload_config.acceptable_types || []}
      allowedExtensions={file_upload_config.acceptable_extensions || []}
      maxSize={file_upload_config.max_size || 50 * 1024 * 1024} />

    <div class="flex-1">
      <textarea
        bind:this={textareaRef}
        bind:value={$messageForm.message.content}
        onkeydown={handleKeydown}
        oninput={autoResize}
        {placeholder}
        disabled={submitting || !chat?.respondable}
        class="w-full resize-none border border-input rounded-md px-3 py-2 text-sm bg-background
               focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent
               min-h-[40px] max-h-[240px] overflow-y-auto disabled:opacity-50 disabled:cursor-not-allowed"
        rows="1"></textarea>
    </div>
    <MicButton
      disabled={submitting || !chat?.respondable}
      accountId={account.id}
      chatId={chat.id}
      onsuccess={handleTranscription}
      onerror={handleTranscriptionError} />
    <button
      onclick={sendMessage}
      disabled={(!$messageForm.message.content.trim() && selectedFiles.length === 0) ||
        submitting ||
        !chat?.respondable}
      class="h-10 w-10 p-0 inline-flex items-center justify-center rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:pointer-events-none disabled:opacity-50">
      {#if submitting}
        <Spinner size={16} class="animate-spin" />
      {:else}
        <ArrowUp size={16} />
      {/if}
    </button>
  </div>
</div>
```

The button order is: **[Attach] [textarea] [Mic] [Send]**

This placement keeps the mic accessible on both desktop and mobile. It sits naturally between the text input and the send button -- close to the user's thumb on mobile.

### Step 7: JS Routes Generation

- [ ] Regenerate JS routes to include the new transcription path

```bash
cd /Users/danieltenner/dev/helix_kit
bin/rails js:routes:generate
```

Note: The MicButton uses a manual `fetch()` URL construction (`/accounts/${accountId}/chats/${chatId}/transcription`) rather than the generated JS routes helper. This is intentional -- the transcription endpoint is a raw JSON API call, not an Inertia navigation, and the URL pattern is simple enough that a template literal is clearer than importing another route helper. However, if preferred, the generated route helper `accountChatTranscriptionPath(accountId, chatId)` will be available after regeneration.

### Step 8: Tests

- [ ] Add controller test for transcription endpoint

**File: `/Users/danieltenner/dev/helix_kit/test/controllers/chats/transcriptions_controller_test.rb`**

```ruby
require "test_helper"

class Chats::TranscriptionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_chats: true)

    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Test Conversation"
    )

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "transcribes audio and returns text" do
    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    ElevenLabsStt.stub(:transcribe, "Hello world") do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio },
        as: :json

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "Hello world", json["text"]
    end
  end

  test "returns error when no speech detected" do
    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    ElevenLabsStt.stub(:transcribe, nil) do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio },
        as: :json

      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      assert_equal "No speech detected", json["error"]
    end
  end

  test "returns error when transcription fails" do
    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    mock_transcribe = ->(_audio) { raise ElevenLabsStt::Error, "Rate limit exceeded" }

    ElevenLabsStt.stub(:transcribe, mock_transcribe) do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio },
        as: :json

      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      assert_includes json["error"], "Rate limit"
    end
  end

  test "rejects request without audio parameter" do
    assert_raises(ActionController::ParameterMissing) do
      post account_chat_transcription_path(@account, @chat), as: :json
    end
  end

  test "rejects request for archived chat" do
    @chat.archive!

    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    post account_chat_transcription_path(@account, @chat),
      params: { audio: audio },
      as: :json

    assert_response :unprocessable_entity
  end

end
```

- [ ] Add test audio fixture file

**File: `/Users/danieltenner/dev/helix_kit/test/fixtures/files/test_audio.webm`**

Create a minimal valid WebM file for testing. Can be generated with:

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -c:a libvorbis test/fixtures/files/test_audio.webm
```

Or use any short audio clip. The actual content doesn't matter since the ElevenLabs call is stubbed in tests.

- [ ] Add model test for ElevenLabsStt

**File: `/Users/danieltenner/dev/helix_kit/test/models/elevenlabs_stt_test.rb`**

```ruby
require "test_helper"

class ElevenLabsSttTest < ActiveSupport::TestCase

  test "raises error when API key is not configured" do
    Rails.application.credentials.stub(:dig, nil) do
      error = assert_raises(ElevenLabsStt::Error) do
        ElevenLabsStt.transcribe(StringIO.new("audio data"))
      end
      assert_includes error.message, "not configured"
    end
  end

end
```

The actual ElevenLabs API integration tests should use VCR cassettes (following the existing project pattern with `test/support/vcr_setup.rb`). For the initial implementation, stubbing the class method in controller tests is sufficient.

---

## Mobile Considerations

### iOS Safari

- **MediaRecorder support**: Safari 14.5+ supports MediaRecorder. The `audio/mp4` MIME type fallback handles Safari's lack of WebM support.
- **getUserMedia**: Requires HTTPS in production (which is already the case via Kamal/Thruster).
- **Auto-play policy**: Not a concern here since we're recording, not playing.
- **Screen lock during recording**: If the user locks their phone while recording, `mediaRecorder.stop()` fires naturally when the stream is interrupted. The `onstop` handler still processes whatever was captured.

### Android Chrome

- **MediaRecorder**: Fully supported. Prefers WebM/Opus which is the ideal format.
- **Permission prompt**: Standard browser permission dialog. The component's error handler covers the `NotAllowedError` case.

### Responsive Layout

The mic button is the same 40x40px as the existing Send button (`h-10 w-10`). The input bar layout is already responsive with `flex gap-2 md:gap-3`. Adding one more button in the flex row works naturally.

On very narrow screens (< 320px), the four elements (attach, textarea, mic, send) might feel tight. The textarea has `flex-1` so it compresses gracefully. The three icon buttons total 120px + gaps, leaving at minimum ~160px for the textarea at 320px viewport width. This is acceptable.

---

## Error Handling Summary

| Error | Where | User sees |
|-------|-------|-----------|
| Microphone denied | MicButton | Error toast: "Microphone access denied..." |
| No microphone | MicButton | Error toast: "No microphone found..." |
| Recording too short | MicButton | Error toast: "Recording too short" |
| Network error | MicButton | Error toast: "Network error during transcription" |
| No speech detected | Controller | Error toast: "No speech detected" |
| ElevenLabs rate limit | Controller | Error toast: "Rate limit exceeded..." |
| ElevenLabs API error | Controller | Error toast: "Transcription service unavailable..." |
| Invalid API key | Controller | Error toast: "Invalid ElevenLabs API key" |
| Chat archived/deleted | Controller | Error toast: "This conversation is archived..." |

All errors use the existing `errorMessage` toast mechanism in `show.svelte` (the red toast in the bottom-right, already implemented at line 1804).

---

## File Summary

### New Files

| File | Purpose |
|------|---------|
| `/app/controllers/chats/transcriptions_controller.rb` | Receives audio, proxies to ElevenLabs, returns text |
| `/app/models/elevenlabs_stt.rb` | ElevenLabs batch STT API wrapper |
| `/app/frontend/lib/components/chat/MicButton.svelte` | Recording toggle button with states |
| `/test/controllers/chats/transcriptions_controller_test.rb` | Controller tests |
| `/test/models/elevenlabs_stt_test.rb` | Model tests |
| `/test/fixtures/files/test_audio.webm` | Test audio fixture |

### Modified Files

| File | Change |
|------|--------|
| `/config/routes.rb` | Add `resource :transcription` inside chats scope |
| `/app/frontend/pages/chats/show.svelte` | Import MicButton, add handlers, add to input bar |

### No New Dependencies

- No new gems (uses `Net::HTTP` from stdlib, matching OuraApi/GithubApi pattern)
- No new npm packages (uses browser MediaRecorder API)

---

## Credentials Setup Checklist

- [ ] Sign up at [elevenlabs.io](https://elevenlabs.io) and get an API key
- [ ] Add to development credentials: `bin/rails credentials:edit --environment development`
- [ ] Add to production credentials: `bin/rails credentials:edit --environment production`

```yaml
ai:
  elevenlabs:
    api_key: "xi_your_key_here"
```

This follows the existing credential pattern from `config/initializers/00_ruby_llm.rb`.
