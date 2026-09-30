# Speech-to-Text Integration

**Date**: 2026-02-14
**Status**: Final (third iteration, all review feedback addressed)

---

## Executive Summary

Add a microphone button to the chat input area that lets users record audio, uploads it to Rails, which proxies to the ElevenLabs Scribe v2 batch API for transcription. The transcribed text is auto-sent as a message with no review step. Tap once to start recording, tap again to stop. Works on both desktop and mobile.

No new gems. No new npm packages. The browser's MediaRecorder API handles recording. Ruby's `Net::HTTP` handles the ElevenLabs API call. A single new controller endpoint receives the audio blob, transcribes it, and returns the text.

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

Four changes:
1. **New Svelte component**: `MicButton.svelte` -- recording toggle with visual feedback
2. **New Rails controller**: `Chats::TranscriptionsController` -- receives audio, calls ElevenLabs, returns text
3. **New lib class**: `ElevenLabsStt` -- stateless API wrapper in `lib/`
4. **Modified file**: `show.svelte` -- add MicButton next to the existing Send button

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

### Step 3: Add `require_respondable_chat` to ChatScoped

- [ ] Move `require_respondable_chat` into the `ChatScoped` concern

The `require_respondable_chat` guard is currently defined independently in both `MessagesController` and `Messages::RetriesController`. Both definitions do the same thing: check `@chat.respondable?` and render an error if not. This is a textbook DRY violation.

Extract it into `ChatScoped` so any controller that includes the concern can use `before_action :require_respondable_chat` without redefining the method.

**File: `/Users/danieltenner/dev/helix_kit/app/controllers/concerns/chat_scoped.rb`**

```ruby
module ChatScoped

  extend ActiveSupport::Concern

  included do
    require_feature_enabled :chats
    before_action :set_chat
  end

  private

  def set_chat
    @chat = current_account.chats.with_discarded.find(params[:chat_id])
  end

  def require_respondable_chat
    return if @chat.respondable?

    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "This conversation is archived or deleted and cannot receive new messages" }
      format.json { render json: { error: "This conversation is archived or deleted" }, status: :unprocessable_entity }
    end
  end

end
```

Note: `MessagesController` and `Messages::RetriesController` do not use `ChatScoped` (they define their own `set_chat` methods with slightly different lookup logic). The private method definitions in those controllers can be removed in a follow-up cleanup, but that refactor is out of scope for this feature. The transcription controller will use `ChatScoped` and get `require_respondable_chat` for free.

### Step 4: Transcription Controller

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

end
```

Skinny controller. All ElevenLabs logic lives in the lib-layer class. The `ChatScoped` concern handles authorization (same pattern as ForksController, ModerationsController, etc.).

### Step 5: ElevenLabs STT API Wrapper

- [ ] Create `ElevenLabsStt` in `lib/`

**File: `/Users/danieltenner/dev/helix_kit/lib/elevenlabs_stt.rb`**

This is a stateless API wrapper. It has no database backing, no per-record behavior, no instance state worth tracking. It lives in `lib/` because that is where standalone library code belongs in Rails. The `config.autoload_lib` in `config/application.rb` ensures it is autoloaded.

```ruby
class ElevenLabsStt

  class Error < StandardError; end

  API_URL = "https://api.elevenlabs.io/v1/speech-to-text"
  MODEL_ID = "scribe_v2"
  READ_TIMEOUT = 60
  OPEN_TIMEOUT = 10

  def self.transcribe(audio_file)
    new.transcribe(audio_file)
  end

  def transcribe(audio_file)
    uri = URI(API_URL)

    request = Net::HTTP::Post.new(uri)
    request["xi-api-key"] = api_key
    request.set_form(
      [
        ["model_id", MODEL_ID],
        ["tag_audio_events", "false"],
        ["timestamps_granularity", "none"],
        ["file", audio_file, { filename: filename_for(audio_file), content_type: content_type_for(audio_file) }]
      ],
      "multipart/form-data"
    )

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT) { |http| http.request(request) }

    handle_response(response)
  end

  private

  def api_key
    Rails.application.credentials.dig(:ai, :elevenlabs, :api_key) ||
      raise(Error, "ElevenLabs API key not configured")
  end

  def filename_for(audio_file)
    audio_file.respond_to?(:original_filename) ? audio_file.original_filename : "audio.webm"
  end

  def content_type_for(audio_file)
    audio_file.respond_to?(:content_type) ? audio_file.content_type : "audio/webm"
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

Design decisions:
- **Named timeout constants**: `READ_TIMEOUT = 60` handles longer audio clips. `OPEN_TIMEOUT = 10` is a reasonable connection timeout. Named constants match the same discipline applied to `MIN_AUDIO_BYTES` on the frontend.
- **Moved to `lib/elevenlabs_stt.rb`**: This is a stateless API wrapper, not a model. `lib/` is honest about what it is.
- **`Net::HTTP::Post#set_form` for multipart**: Eliminates the hand-rolled boundary builder entirely. No `SecureRandom.hex(16)`, no manual `\r\n` concatenation. The standard library handles it.
- **No `ENV` fallback**: Credentials only, matching the convention used by OuraApi and GithubApi.
- `tag_audio_events: false` -- we don't want "(laughter)" in chat messages
- `timestamps_granularity: none` -- we only need the text, not word timing
- Language detection is automatic (no `language_code` parameter)
- Class method `ElevenLabsStt.transcribe(file)` for ergonomic one-liner calls

### Step 6: MicButton Svelte Component

- [ ] Create `MicButton.svelte`

**File: `/Users/danieltenner/dev/helix_kit/app/frontend/lib/components/chat/MicButton.svelte`**

```svelte
<script>
  import { Microphone, MicrophoneSlash, Spinner } from 'phosphor-svelte';

  const MIN_AUDIO_BYTES = 1000;

  let {
    disabled = false,
    accountId,
    chatId,
    onsuccess,
    onerror,
  } = $props();

  let state = $state('idle');

  let mediaRecorder = null;
  let audioChunks = [];

  const isRecording = $derived(state === 'recording');
  const isTranscribing = $derived(state === 'transcribing');

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

        if (blob.size < MIN_AUDIO_BYTES) {
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

Notes:
- **`mediaRecorder` and `audioChunks` are plain `let` variables, not `$state`**: These are internal callback state, not reactive UI state. Nothing in the template reads them directly. Only `state` drives the UI, so only `state` needs `$state`.
- **`MIN_AUDIO_BYTES` named constant**: The magic number 1000 now has a name at the top of the script block.
- **CSRF lookup uses `.content`**: The idiomatic DOM property for `<meta>` elements. The existing codebase is split between `.content` and `.getAttribute('content')` -- both work, but `.content` is shorter and correct. The follow-up CSRF cleanup should normalize all instances to `.content`.

### Step 7: Integrate MicButton into Chat Interface

- [ ] Modify `show.svelte` to include MicButton

**File: `/Users/danieltenner/dev/helix_kit/app/frontend/pages/chats/show.svelte`**

Add import (around line 36, with other chat component imports):

```svelte
import MicButton from '$lib/components/chat/MicButton.svelte';
```

Add handler function (near the `sendMessage` function, around line 692). Uses the existing `errorMessage` state with `setTimeout` clear, matching the pattern already used throughout the file:

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

Note: The `errorMessage` + `setTimeout` pattern is repeated 8+ times in `show.svelte`. A `showError(message, duration)` helper would eliminate all that duplication. That refactor should happen, but separately from this feature -- it is a pre-existing problem, not one introduced here.

Modify the message input area (around line 1662). Add `MicButton` between the textarea and the Send button:

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

### Step 8: JS Routes Generation

- [ ] Regenerate JS routes to include the new transcription path

```bash
cd /Users/danieltenner/dev/helix_kit
bin/rails js:routes:generate
```

The MicButton uses a manual `fetch()` URL construction rather than the generated JS routes helper. This is intentional -- the transcription endpoint is a raw JSON API call, not an Inertia navigation, and the URL pattern is simple enough that a template literal is clearer. However, the generated route helper `accountChatTranscriptionPath(accountId, chatId)` will be available after regeneration if preferred.

### Step 9: Tests

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

    sign_in @user
  end

  test "transcribes audio and returns text" do
    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    ElevenLabsStt.stub(:transcribe, "Hello world") do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio }

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "Hello world", json["text"]
    end
  end

  test "returns error when no speech detected" do
    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    ElevenLabsStt.stub(:transcribe, nil) do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio }

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
        params: { audio: audio }

      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      assert_includes json["error"], "Rate limit"
    end
  end

  test "rejects request without audio parameter" do
    assert_raises(ActionController::ParameterMissing) do
      post account_chat_transcription_path(@account, @chat)
    end
  end

  test "rejects request for archived chat" do
    @chat.archive!

    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    post account_chat_transcription_path(@account, @chat),
      params: { audio: audio }

    assert_response :unprocessable_entity
  end

  test "requires authentication" do
    delete logout_path

    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    post account_chat_transcription_path(@account, @chat),
      params: { audio: audio }

    assert_response :redirect
  end

  test "scopes to current account" do
    other_user = User.create!(email_address: "sttother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(model_id: "openrouter/auto")

    audio = fixture_file_upload("files/test_audio.webm", "audio/webm")

    post account_chat_transcription_path(@account, other_chat),
      params: { audio: audio }

    assert_response :not_found
  end

end
```

- [ ] Add test audio fixture file

**File: `/Users/danieltenner/dev/helix_kit/test/fixtures/files/test_audio.webm`**

Create a minimal valid WebM file for testing:

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -c:a libvorbis test/fixtures/files/test_audio.webm
```

Or use any short audio clip. The actual content does not matter since the ElevenLabs call is stubbed in tests.

- [ ] Add comprehensive model tests for ElevenLabsStt

**File: `/Users/danieltenner/dev/helix_kit/test/lib/elevenlabs_stt_test.rb`**

```ruby
require "test_helper"
require "webmock/minitest"

class ElevenLabsSttTest < ActiveSupport::TestCase

  setup do
    @audio = StringIO.new("fake audio data")
    @api_url = ElevenLabsStt::API_URL
  end

  test "returns stripped text on successful response" do
    stub_request(:post, @api_url)
      .to_return(status: 200, body: { text: "  Hello world  " }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      assert_equal "Hello world", ElevenLabsStt.transcribe(@audio)
    end
  end

  test "returns nil when response text is empty" do
    stub_request(:post, @api_url)
      .to_return(status: 200, body: { text: "" }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      assert_nil ElevenLabsStt.transcribe(@audio)
    end
  end

  test "returns nil when response text is whitespace only" do
    stub_request(:post, @api_url)
      .to_return(status: 200, body: { text: "   " }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      assert_nil ElevenLabsStt.transcribe(@audio)
    end
  end

  test "raises on 401 unauthorized" do
    stub_request(:post, @api_url)
      .to_return(status: 401, body: { error: "Unauthorized" }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_equal "Invalid ElevenLabs API key", error.message
    end
  end

  test "raises on 429 rate limit" do
    stub_request(:post, @api_url)
      .to_return(status: 429, body: { error: "Too many requests" }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "rate limit"
    end
  end

  test "raises on 422 with error message from response" do
    stub_request(:post, @api_url)
      .to_return(status: 422, body: { error: { message: "Invalid model identifier" } }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "Invalid model identifier"
    end
  end

  test "raises on 422 with unparseable body" do
    stub_request(:post, @api_url)
      .to_return(status: 422, body: "not json")

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "Invalid request"
    end
  end

  test "raises on 500 server error" do
    stub_request(:post, @api_url)
      .to_return(status: 500, body: "Internal Server Error")

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "service unavailable"
    end
  end

  test "raises when API key is not configured" do
    Rails.application.credentials.stub(:dig, nil) do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "not configured"
    end
  end

  test "sends correct headers" do
    request_stub = stub_request(:post, @api_url)
      .with(headers: { "xi-api-key" => "test-api-key" })
      .to_return(status: 200, body: { text: "Hello" }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      ElevenLabsStt.transcribe(@audio)
    end

    assert_requested request_stub
  end

end
```

The tests cover all five branches in `handle_response` (200, 401, 429, 422, else) plus edge cases (empty text, whitespace text, unparseable 422 body, missing API key, correct headers).

Key changes from second iteration:
- **Replaced Mocha `.stubs` with Minitest `.stub`**: The previous iteration used `Rails.application.credentials.stubs(:dig).with(:ai, :elevenlabs, :api_key).returns("test-api-key")` which is Mocha syntax. This project does not have Mocha. Now each test that needs credentials wraps in `Rails.application.credentials.stub(:dig, "test-api-key") do ... end`, which is Minitest's block-based stub API.
- **No global credential stub in `setup`**: Only the "missing API key" test and the "correct headers" test actually need credential control. The other tests need it too (since `api_key` is called before the HTTP request), but they get it through the same block-based pattern. This keeps each test self-contained and honest about its dependencies.
- **Minitest `.stub` does not support argument matching**: It returns the stubbed value regardless of what arguments `dig` receives. This is acceptable -- `ElevenLabsStt` only calls `dig` once, so there is no ambiguity.

Uses WebMock's `stub_request` to mock HTTP calls, matching the established pattern from `WebToolTest`.

Note on VCR interaction: VCR is configured with `allow_http_connections_when_no_cassette = false` and hooks into WebMock. The `require "webmock/minitest"` in the test file works alongside VCR -- WebMock stubs take precedence over VCR cassettes. The `WebToolTest` follows this exact pattern.

---

## Mobile Considerations

### iOS Safari

- **MediaRecorder support**: Safari 14.5+ supports MediaRecorder. The `audio/mp4` MIME type fallback handles Safari's lack of WebM support.
- **getUserMedia**: Requires HTTPS in production (which is already the case via Kamal/Thruster).
- **Auto-play policy**: Not a concern here since we are recording, not playing.
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

All errors use the existing `errorMessage` toast mechanism in `show.svelte` (the red toast at line 1804), surfaced via the `onerror` callback.

---

## File Summary

### New Files

| File | Purpose |
|------|---------|
| `/app/controllers/chats/transcriptions_controller.rb` | Receives audio, proxies to ElevenLabs, returns text |
| `/lib/elevenlabs_stt.rb` | Stateless ElevenLabs batch STT API wrapper |
| `/app/frontend/lib/components/chat/MicButton.svelte` | Recording toggle button with states |
| `/test/controllers/chats/transcriptions_controller_test.rb` | Controller tests |
| `/test/lib/elevenlabs_stt_test.rb` | API wrapper tests (all response branches) |
| `/test/fixtures/files/test_audio.webm` | Test audio fixture |

### Modified Files

| File | Change |
|------|--------|
| `/config/routes.rb` | Add `resource :transcription` inside chats scope |
| `/app/controllers/concerns/chat_scoped.rb` | Add `require_respondable_chat` method |
| `/app/frontend/pages/chats/show.svelte` | Import MicButton, add handlers, add to input bar |

### No New Dependencies

- No new gems (uses `Net::HTTP` from stdlib)
- No new npm packages (uses browser MediaRecorder API)

---

## Follow-up Cleanup (Out of Scope)

These are pre-existing issues surfaced during this spec review. They should be addressed separately, not blocked on this feature:

1. **Extract `showError` helper in `show.svelte`**: The `errorMessage = ...; setTimeout(...)` pattern is repeated 8+ times. A single `showError(message, duration = 5000)` function would eliminate all of it.

2. **Extract shared CSRF fetch utility**: The `document.querySelector('meta[name="csrf-token"]')?.content` pattern appears 6+ times in `show.svelte` and in other pages. A shared `csrfFetch` wrapper would DRY this up. When extracted, normalize all existing `.getAttribute('content')` calls to `.content` for consistency.

3. **Consolidate `require_respondable_chat` in existing controllers**: `MessagesController` and `Messages::RetriesController` each define their own `require_respondable_chat`. Now that `ChatScoped` provides one, those controllers could use the concern's version (though they have different `set_chat` logic, so this requires careful migration).

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
