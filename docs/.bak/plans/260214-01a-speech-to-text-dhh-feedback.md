# DHH Review: Speech-to-Text Integration Spec

**Date**: 2026-02-14
**Reviewing**: `/docs/plans/260214-01a-speech-to-text.md`

---

## Overall Assessment

This is a well-structured, focused spec. The instincts are right: no new gems, no new npm packages, skinny controller, business logic in the model layer, ChatScoped concern for authorization. The feature scope is disciplined -- record, transcribe, send, done. No settings panel, no language picker, no audio playback preview. That restraint is correct.

But the spec makes one structural mistake that undermines the whole "follow existing patterns" claim, and there are several smaller issues worth fixing before implementation.

---

## Critical Issues

### 1. ElevenLabsStt Does Not Follow the Existing Pattern

The spec says it follows "the existing pattern of OuraApi, GithubApi, and WebTool." It does not. Those are fundamentally different structures:

- `OuraApi` and `GithubApi` are **concerns** in `app/models/concerns/` that get mixed into ActiveRecord models (`OuraIntegration`, `GithubIntegration`). They encapsulate API communication as behavior mixed into a persistent model.
- `WebTool` is a tool class in `app/tools/` that inherits from `RubyLLM::Tool`.

`ElevenLabsStt` is neither of those. It is a standalone plain Ruby class in `app/models/` with no database backing. That is, quite literally, a **service object** -- the very thing the architecture doc explicitly says to avoid.

The spec even acknowledges this awkwardness: "It is a simple class, not an ActiveRecord model." If you have to explain why something belongs where it is, it probably does not belong there.

The question is: what is the right home for this? Two options:

**Option A**: Make it a concern. If you anticipate ever needing STT configuration per-account or per-user (API key overrides, usage tracking, model selection), create an `ElevenLabsSttApi` concern in `app/models/concerns/` and mix it into a future `SttIntegration` model or even into `Chat` itself. This mirrors the OuraApi/GithubApi pattern exactly.

**Option B**: If this truly is a stateless utility with no per-record behavior, put it in `lib/` -- that is where standalone library code lives in Rails. `lib/elevenlabs_stt.rb` is honest about what it is.

For the current scope (no per-user config, no usage tracking, just a single API key in credentials), Option B is the more honest choice. A class with only class methods and no state is a function wrapped in an object. Do not pretend it is a model.

However, if the project already has precedent for plain classes in `app/models/` and the team is comfortable with that convention, then keep it there but drop the claim that it follows OuraApi/GithubApi patterns. It does not. Call it what it is: a simple API wrapper. That is fine. Just be honest about the pattern.

### 2. The Multipart Body Builder is Unnecessary Complexity

Hand-rolling multipart form data with boundary strings in 2026 is masochism. Ruby's standard library has had this solved since forever. `Net::HTTP::Post` supports `set_form` with multipart encoding:

```ruby
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
    read_timeout: 60, open_timeout: 10) { |http| http.request(request) }

  handle_response(response)
end

private

def filename_for(audio_file)
  audio_file.respond_to?(:original_filename) ? audio_file.original_filename : "audio.webm"
end

def content_type_for(audio_file)
  audio_file.respond_to?(:content_type) ? audio_file.content_type : "audio/webm"
end
```

This eliminates `build_multipart_body` entirely -- 20+ lines of hand-crafted boundary juggling replaced by a single method call that Ruby provides out of the box. The `SecureRandom.hex(16)` boundary generation, the manual `\r\n` concatenation, all of it vanishes.

Never hand-roll what the standard library already handles.

---

## Improvements Needed

### 3. The `require_respondable_chat` Before Action Likely Belongs in ChatScoped

Look at the ChatScoped concern -- it sets `@chat` and enforces feature flags. The `respondable?` check is authorization logic: "can this chat receive new input?" Every controller in `chats/` that writes to the chat (messages#create, forks#create, agent_triggers#create, and now transcriptions#create) presumably needs this same guard.

If it is not already in ChatScoped, consider adding it there or as a shared `before_action` option rather than redefining it in each controller. If other controllers already duplicate this check, extract it once:

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
    render json: { error: "This conversation is archived or deleted" }, status: :unprocessable_entity
  end
end
```

Then in the controller: `before_action :require_respondable_chat`. Clean, DRY, no method definition needed in the controller itself.

Check the messages controller first -- if it already has a similar guard, that confirms this belongs in the concern.

### 4. Error Toast Pattern is Duplicated

The spec defines `handleTranscriptionError` like this:

```javascript
function handleTranscriptionError(message) {
  errorMessage = message;
  setTimeout(() => (errorMessage = null), 5000);
}
```

But `show.svelte` already has this exact pattern repeated at least 8 times:

```javascript
errorMessage = 'Failed to update title';
setTimeout(() => (errorMessage = null), 3000);
```

This is a textbook DRY violation. Before adding a ninth instance, extract a helper:

```javascript
function showError(message, duration = 5000) {
  errorMessage = message;
  setTimeout(() => (errorMessage = null), duration);
}
```

Then `handleTranscriptionError` becomes `onerror={showError}` -- no wrapper function needed. Better yet, fix the existing eight instances in the same change. That said, this is a pre-existing problem, not one introduced by this spec. Do not let fixing it block the feature, but do note it.

### 5. The `audioChunks` Mutation Pattern Fights Svelte 5 Reactivity

In the MicButton component:

```javascript
let audioChunks = $state([]);

recorder.ondataavailable = (event) => {
  if (event.data.size > 0) {
    audioChunks.push(event.data);  // Mutation!
  }
};
```

In Svelte 5, `$state` tracks reactivity via assignment, not mutation. `Array.push()` on a `$state` array works in Svelte 5 (they added deep reactivity for arrays), but it is a pattern that confuses developers who expect Svelte's assignment-based reactivity model. More importantly, `audioChunks` does not need to be reactive at all -- nothing in the template reads it. It is purely internal state used between callbacks.

Just use a plain `let`:

```javascript
let audioChunks = [];
```

Same for `mediaRecorder` -- nothing in the template reads its value directly. The template reads `state`, `isRecording`, and `isTranscribing`. Making `mediaRecorder` reactive via `$state` is unnecessary overhead.

```javascript
let mediaRecorder = null;
let audioChunks = [];
```

Only use `$state` for values that drive the UI. This is a Svelte 5 discipline issue.

### 6. CSRF Token Fetch is Brittle

```javascript
const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
```

This works but is fragile and ad-hoc. Check if the project has an existing pattern for making fetch requests with CSRF tokens. In an Inertia app, Axios is typically configured with CSRF handling globally. If the project uses Axios elsewhere for non-Inertia requests, use it here too. If not, at minimum extract the CSRF token fetch into a utility rather than inlining it in a component.

If this is genuinely the first non-Inertia fetch request in the codebase, document that decision clearly. It introduces a second HTTP client pattern alongside Inertia's router.

### 7. The Model Test is Thin

The `ElevenLabsSttTest` has exactly one test: that it raises when the API key is missing. That is the least interesting behavior. The `handle_response` method has four branches (200, 401, 429, 422, else). Test them:

```ruby
class ElevenLabsSttTest < ActiveSupport::TestCase
  test "returns stripped text on successful response" do
    stub_successful_response("  Hello world  ") do
      assert_equal "Hello world", ElevenLabsStt.transcribe(audio_fixture)
    end
  end

  test "returns nil when response text is empty" do
    stub_successful_response("") do
      assert_nil ElevenLabsStt.transcribe(audio_fixture)
    end
  end

  test "raises on 401 unauthorized" do
    stub_error_response(401) do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(audio_fixture) }
      assert_equal "Invalid ElevenLabs API key", error.message
    end
  end

  test "raises on 429 rate limit" do
    stub_error_response(429) do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(audio_fixture) }
      assert_includes error.message, "rate limit"
    end
  end
end
```

The controller tests are solid. The model tests should match that level of rigor. Use WebMock or VCR stubs to test the HTTP response handling without hitting the real API.

---

## What Works Well

**The scope is right.** Tap to record, tap to stop, auto-send. No preview step, no audio playback, no transcription editing. This is the minimum viable feature and the correct one to ship first.

**The controller is genuinely skinny.** Five lines in `create`. That is what a controller action should look like. The `ChatScoped` concern handles all the authorization boilerplate. Good.

**The state machine in MicButton is clean.** Three states (idle, recording, transcribing) with clear transitions. No ambiguous intermediate states. The derived booleans (`isRecording`, `isTranscribing`, `isBusy`) make the template readable.

**The MIME type negotiation is pragmatic.** WebM with Opus for Chrome/Firefox, MP4 for Safari, then default. Covers the real-world browser landscape without overthinking it.

**The error handling table is excellent.** Every error case is documented with where it occurs and what the user sees. This is the kind of spec detail that prevents "what happens when..." questions during implementation.

**No new dependencies.** Using `Net::HTTP` from stdlib and the browser's MediaRecorder API. This is the correct instinct. A gem for one API call is wasteful. An npm package for an API the browser already provides is bloat.

**The route is singular** (`resource :transcription`). Correct -- there is one transcription per audio upload, not a collection. This follows the same pattern as `resource :fork`, `resource :archive`, etc.

---

## Minor Notes

- The `as: :json` in the controller tests may not play well with `fixture_file_upload`. Multipart file uploads and JSON content types can conflict. Test this during implementation. You may need to drop `as: :json` and let the content type be inferred from the multipart form data.

- The 1000-byte minimum blob check is a reasonable heuristic but magic numbers deserve a name. Consider `const MIN_AUDIO_BYTES = 1000` at the top of the script block.

- The `ENV["ELEVENLABS_API_KEY"]` fallback in the API key lookup is inconsistent with the OuraApi and GithubApi patterns, which only use `Rails.application.credentials`. Keep it consistent -- credentials only, no ENV fallback. If someone needs an ENV-based key for development, they can use the development credentials file.

---

## Summary of Required Changes

1. **Move ElevenLabsStt to `lib/` or make it a concern** -- do not put a stateless service object in `app/models/` and call it a model
2. **Use `Net::HTTP::Post#set_form` for multipart** -- delete the hand-rolled boundary builder
3. **Consider extracting `require_respondable_chat` to ChatScoped** -- check if other controllers duplicate this
4. **Drop `$state` from `audioChunks` and `mediaRecorder`** -- they are not reactive, do not pretend they are
5. **Remove the `ENV` fallback for the API key** -- follow the credentials-only convention
6. **Beef up the model tests** -- test all response code branches

Everything else is solid. Ship it.
