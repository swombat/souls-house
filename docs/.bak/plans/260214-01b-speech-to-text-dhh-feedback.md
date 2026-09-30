# DHH Review: Speech-to-Text Integration Spec (Second Iteration)

**Date**: 2026-02-14
**Reviewing**: `/docs/plans/260214-01b-speech-to-text.md`

---

## Overall Assessment

This is a dramatically improved spec. Every critical issue from the first review has been addressed, and addressed correctly: `ElevenLabsStt` moved to `lib/` where it belongs, the hand-rolled multipart boundary builder is gone in favor of `Net::HTTP::Post#set_form`, `require_respondable_chat` extracted into `ChatScoped`, `audioChunks` and `mediaRecorder` demoted to plain `let`, the `ENV` fallback removed, the model tests expanded to cover all response branches, and the CSRF pattern honestly documented rather than glossed over. The scope notes are now forthright about what is pre-existing debt versus what this feature introduces.

There is one real bug in the test code (Mocha API on a project that does not use Mocha) and a few smaller items worth tightening. Otherwise, this is ready to implement.

---

## Critical Issues

### 1. The ElevenLabsStt Tests Use Mocha Syntax -- This Project Does Not Have Mocha

The `ElevenLabsSttTest` (Step 9) uses `Rails.application.credentials.stubs(:dig)`:

```ruby
setup do
  Rails.application.credentials.stubs(:dig).with(:ai, :elevenlabs, :api_key).returns("test-api-key")
end
```

This is Mocha's `.stubs` API. The project's `Gemfile` has no Mocha gem. The existing test suite uses Minitest's `.stub` method exclusively (see `test/models/concerns/telegram_notifiable_test.rb`, `test/controllers/github_integration_controller_test.rb`, `test/jobs/database_backup_job_test.rb`, etc.).

These tests will not run. They will blow up with `NoMethodError: undefined method 'stubs'`.

The fix is to use Minitest's block-based `.stub`:

```ruby
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
```

The issue: Minitest's `.stub` takes `(method_name, return_value, &block)` and does not support argument matching with `.with`. For a `dig` call with specific arguments, this means the stub returns `"test-api-key"` regardless of what arguments `dig` receives. That is acceptable here -- `ElevenLabsStt` only calls `dig` once, so there is no ambiguity.

Alternatively, wrap the credential lookup in a way that the tests can control. The simplest pattern matching the codebase is to stub at the HTTP level (which WebMock already handles) and test the credential-missing case separately by temporarily unsetting the credential:

```ruby
test "raises when API key is not configured" do
  Rails.application.credentials.stub(:dig, nil) do
    error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
    assert_includes error.message, "not configured"
  end
end
```

Every test in the file needs this fix. The `setup` block should not stub credentials at all -- let each test that needs it wrap in a `.stub` block, or better yet, since WebMock stubs the HTTP layer regardless, only the "missing API key" and "correct headers" tests need to touch credentials.

---

## Improvements Needed

### 2. The "Three Changes" List Has Four Items

Line 28: "Three changes:" followed by items 1 through 4. This is a numbering error. Trivial, but it erodes trust in the document's precision. Make it "Four changes:" or renumber.

### 3. The ChatScoped `require_respondable_chat` Has a Dual-Format Response -- The Controller Only Needs JSON

The extracted `require_respondable_chat` in the spec (Step 3) responds to both HTML and JSON:

```ruby
def require_respondable_chat
  return if @chat.respondable?

  respond_to do |format|
    format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "..." }
    format.json { render json: { error: "..." }, status: :unprocessable_entity }
  end
end
```

This is the right design for a shared concern method -- it should handle both formats because different controllers in the `chats/` namespace may respond to different content types. The `MessagesController` responds to both HTML and JSON, and the transcription controller responds only to JSON. Having both formats in the concern method means it works for all consumers. This is correct.

However, since this is now shared infrastructure, note that the existing `MessagesController` and `Messages::RetriesController` each have their own `require_respondable_chat` with identical logic. The spec correctly notes this cleanup is out of scope (line 111), which is the right call -- do not mix a refactor of those controllers into this feature. But do verify that the messages in the concern match the existing messages exactly, or you will introduce subtle behavioral differences for existing callers when they eventually adopt the concern version.

Comparing the spec's version against the existing `MessagesController` (line 93) and `Messages::RetriesController` (line 32): the messages are identical. Good.

### 4. Consider Naming the 60-Second Read Timeout

The `ElevenLabsStt` class names its model ID as `MODEL_ID` and its API URL as `API_URL`, but the timeouts are inline magic numbers:

```ruby
response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
  read_timeout: 60, open_timeout: 10) { |http| http.request(request) }
```

The spec correctly named `MIN_AUDIO_BYTES` on the frontend following the first review's feedback. The same discipline applies here. Sixty seconds is a meaningful choice ("handles longer audio clips" per the spec). Ten seconds for open timeout is a meaningful choice too. Name them:

```ruby
READ_TIMEOUT = 60
OPEN_TIMEOUT = 10
```

This is a minor point, not a blocker. But consistency matters -- if the spec's philosophy is "magic numbers deserve names" (which it demonstrated by extracting `MIN_AUDIO_BYTES`), apply it uniformly.

### 5. The `MicButton` CSRF Token Lookup Diverges From the Existing Pattern

The spec uses `.content`:

```javascript
const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
```

But the existing codebase is split. Some instances use `.content`, others use `.getAttribute('content')`:

- `show.svelte` line 337: `.getAttribute('content')`
- `show.svelte` line 736: `.content`
- `show.svelte` line 1008: `.getAttribute('content')`
- `navbar.svelte` line 82: `.content`

Both work. `.content` is the correct DOM property for `<meta>` elements, and `.getAttribute('content')` is the generic attribute accessor. The difference is inconsequential in practice, but the inconsistency across the codebase is noise. The spec should pick one and use it. `.content` is shorter and idiomatic -- use it. This is not a problem the spec introduces; it is pre-existing. But since the spec already documents the CSRF pattern as a follow-up cleanup candidate, note that the cleanup should also normalize `.getAttribute('content')` to `.content` across the board.

---

## Verifying First Review Feedback Was Addressed

Going through each point from the first review:

1. **"Move ElevenLabsStt to `lib/` or make it a concern"** -- Moved to `lib/elevenlabs_stt.rb`. The rationale is honest: "It has no database backing, no per-record behavior, no instance state worth tracking." Correct. Addressed.

2. **"Use `Net::HTTP::Post#set_form` for multipart"** -- Done. The hand-rolled boundary builder is gone. The `set_form` call is clean and correct. Addressed.

3. **"Consider extracting `require_respondable_chat` to ChatScoped"** -- Done. The concern now provides the method. The spec correctly notes that existing controllers are not migrated in this feature. Addressed.

4. **"Drop `$state` from `audioChunks` and `mediaRecorder`"** -- Done. Both are plain `let`. Only `state` remains `$state`, which is correct since it drives the template. The unused `isBusy` derived mentioned in the first review is also gone. Addressed.

5. **"Remove the `ENV` fallback for the API key"** -- Done. Credentials only, matching `OuraApi` and `GithubApi`. Addressed.

6. **"Beef up the model tests"** -- Done. The test file now covers 200 (success), 200 (empty text), 200 (whitespace text), 401, 429, 422 (with message), 422 (unparseable), 500, missing API key, and correct headers. All five branches in `handle_response` plus edge cases. Addressed (modulo the Mocha bug noted above).

7. **"`as: :json` may conflict with `fixture_file_upload`"** (minor note) -- Dropped `as: :json` from controller tests. Addressed.

8. **"Magic number 1000 deserves a name"** (minor note) -- Named as `MIN_AUDIO_BYTES`. Addressed.

9. **"Error toast duplication"** (improvement suggestion) -- Honestly documented as pre-existing debt with a clear follow-up note. Correct approach -- do not block a feature on fixing pre-existing problems. Addressed.

10. **"CSRF fetch is brittle / document that decision"** (improvement suggestion) -- The spec now contains a thorough accounting: six instances in `show.svelte`, the fact that this is the first non-Inertia fetch in a standalone component, and a clear statement that a shared `csrfFetch` utility should be a separate cleanup. Addressed.

All ten points from the first review are resolved.

---

## What Works Well

**The `lib/` placement is honest.** The spec does not pretend `ElevenLabsStt` is something it is not. "A stateless API wrapper" in `lib/` is exactly right. The explanation of why it is not a model, not a concern, and not a tool is clear and correct. The `config.autoload_lib` line in `config/application.rb` confirms it will be autoloaded.

**The controller is still exemplary.** Five lines in `create`, plus a rescue. It reads like documentation. The `ChatScoped` concern does all the setup. This is what a controller should look like.

**The class-method-delegates-to-instance pattern is a nice touch.** `ElevenLabsStt.transcribe(file)` for ergonomic one-liner calls, with the actual work in instance methods. This keeps the public API clean while allowing the private methods to use instance state (the parsed api key, helpers). It is a small thing, but it shows attention to the caller's experience.

**The test coverage is thorough.** Seven controller tests covering the happy path, empty transcription, API errors, missing params, archived chats, authentication, and account scoping. Ten model tests covering every response branch plus edge cases. The `StringIO` fake audio in the model tests is pragmatic -- no need for real audio when HTTP is stubbed.

**The follow-up cleanup section is mature engineering.** Calling out `showError`, `csrfFetch`, and the `require_respondable_chat` consolidation as separate work items -- with reasoning for why they are out of scope -- demonstrates judgment. Ship the feature, clean up later, but document the debt so it does not get forgotten.

**The mobile considerations section is practical.** iOS Safari's `audio/mp4` fallback, the HTTPS requirement for `getUserMedia`, the screen-lock behavior -- these are the real-world edge cases that matter. No hand-waving, no "we'll figure it out later."

---

## Summary of Required Changes

1. **Fix the Mocha syntax in `ElevenLabsSttTest`** -- replace `.stubs(:dig).with(...).returns(...)` with Minitest's `.stub(:dig, value, &block)` pattern. This is a bug that will cause test failures.

2. **Fix "Three changes" to "Four changes"** -- numbering error on line 28.

Everything else is solid. The Mocha bug is the only thing that would prevent implementation. Fix that and ship it.
