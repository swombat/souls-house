# Twitter Tool v1b Spec -- DHH-Style Review

## Overall Assessment

This is a clean, tight spec. The v1a feedback was applied faithfully and with good judgment -- the polymorphic dispatch is gone, the custom `RateLimited` exception is gone, the `posted_at` column is gone, the JSON construction is fixed, the error helpers are collapsed, the controller uses `build_x_integration` + `update!`. The result is a 30-line tool that does exactly one thing, backed by a concern and model that follow the established `GithubIntegration` / `GithubApi` pattern precisely. This is ready to implement with only minor corrections.

---

## v1a Feedback Items -- Disposition

| Feedback Item | Status | Notes |
|---------------|--------|-------|
| Drop polymorphic action dispatch for single-action tool | Applied correctly | `execute(text:)` directly, no action param, no dispatch |
| Fix JSON construction to `{ text: text }.to_json` | Applied correctly | Line 115 of the spec |
| Fix `TweetLog.agent` consistency (optional vs non-optional) | Applied correctly | Architecture diagram, migration, and model all agree on non-optional |
| Collapse error helpers to one-liner | Applied correctly | Single `error(msg)` one-liner, everything else inline |
| Drop `RateLimited` custom exception subclass | Applied correctly | Single `Error` class, rate limit info in message string |
| Drop `posted_at` column | Applied correctly | Uses `created_at`, `recent` scope orders by `created_at` |
| Controller `build_x_integration` + `update!` | Applied correctly | Single database write in the `update` action |
| Pin `x` gem response as Hash | Applied correctly | Direct `response.dig("data", "id")`, no conditional dance |

All seven items from the v1a review were addressed. No regressions.

---

## Remaining Issues

### 1. The `e.reset_in` call on `X::TooManyRequests` needs verification

Line 123 of the spec:

```ruby
rescue X::TooManyRequests => e
  raise Error, "Rate limited. Retry in #{e.reset_in || 900} seconds."
```

Per the x-ruby gem docs in `/docs/stack/x-ruby-gem.md` (line 259), `e.reset_in` is a direct attribute on `X::TooManyRequests` -- it is *not* nested under `e.rate_limit`. So `e.reset_in || 900` is the correct call. Good.

However, the v1a feedback (line 356 of the feedback doc) used `e.rate_limit&.reset_in || 900`, and the v1a spec itself (line 140) used `e.rate_limit&.reset_in || 900`. The v1b spec simplified this to `e.reset_in || 900`, which is correct per the gem docs (`e.reset_in` is documented as a convenience alias). This is actually an improvement over the feedback's own suggestion. Well done.

No action needed.

### 2. Minor: the `integration_json` method does not expose credential presence

In `/app/controllers/x_integration_controller.rb` (the spec, Step 11), the `integration_json` method returns:

```ruby
{
  id: integration.id,
  enabled: integration.enabled?,
  connected: integration.connected?,
  x_username: integration.x_username
}
```

This is correct -- credentials should never be sent to the frontend. But compare to `GithubIntegrationController#integration_json` which also exposes `repository_full_name` and `commits_synced_at`. The X integration has no equivalent state fields, so this is appropriately minimal.

No action needed.

### 3. The `destroy` action calls `disconnect!` but the route says `destroy`

The spec routes:

```ruby
resource :x_integration, only: %i[show update destroy], controller: "x_integration"
```

And the controller's `destroy` action calls `integration.disconnect!`, which clears credentials but keeps the record. This mirrors `GithubIntegrationController#destroy` exactly (line 87-91 of the existing controller), so it is pattern-consistent. The "destroy" route name is slightly misleading since the record survives, but that is a pre-existing convention in this codebase.

No action needed.

### 4. Minor nit: `e.reset_in` could theoretically be `nil`

The gem docs say `e.reset_in` returns "Integer seconds until reset." If the X API response lacks the `x-rate-limit-reset` header, `reset_in` could be `nil`, making the `|| 900` fallback correct and necessary.

However, verify during implementation that `e.reset_in` returns `nil` (not `0` or raises) when the header is missing. The `|| 900` fallback would not catch a `0` return. This is an implementation-time verification, not a spec issue.

No action needed in the spec.

### 5. The test for rate limits may not trigger the `X::TooManyRequests` exception

In Step 9, the rate limit test stubs a 429 response:

```ruby
stub_request(:post, "https://api.twitter.com/2/tweets")
  .to_return(
    status: 429,
    body: { detail: "Too Many Requests" }.to_json,
    headers: {
      "Content-Type" => "application/json",
      "x-rate-limit-reset" => (Time.current + 900).to_i.to_s
    }
  )
```

This works if the `x` gem raises `X::TooManyRequests` when it receives a 429 status from webmock. The gem uses `Net::HTTP` under the hood and inspects the response status code to raise the appropriate exception. Verify during implementation that webmock's stubbed 429 triggers the gem's exception hierarchy correctly. It almost certainly does -- the gem parses `response.code` -- but it is worth a quick manual test.

No action needed in the spec, but worth noting for the implementer.

### 6. Missing test for `XIntegration#post_tweet!` directly

The `XIntegrationTest` (Step 10) tests `connected?`, `disconnect!`, uniqueness, and the `enabled` scope -- but it does not test `post_tweet!` directly on the model. The `TwitterToolTest` exercises `post_tweet!` indirectly through the tool, which provides coverage, but a direct model test for `post_tweet!` would be more precise. Consider adding one:

```ruby
test "post_tweet! creates tweet log and returns result" do
  integration = XIntegration.create!(
    account: @account,
    api_key: "k", api_key_secret: "ks",
    access_token: "t", access_token_secret: "ts",
    x_username: "bot"
  )
  agent = agents(:research_assistant)

  stub_request(:post, "https://api.twitter.com/2/tweets")
    .to_return(
      status: 201,
      body: { data: { id: "123", text: "Hello" } }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

  result = integration.post_tweet!("Hello", agent: agent)

  assert_equal "123", result[:tweet_id]
  assert_equal 1, integration.tweet_logs.count
end
```

This is a minor gap, not a blocker. The tool tests provide indirect coverage.

### 7. Consider `has_many :tweet_logs, dependent: :destroy` on `XIntegration`

The spec has this on `XIntegration` (Step 5, line 162):

```ruby
has_many :tweet_logs, dependent: :destroy
```

Good -- this is correct. If an `XIntegration` record is destroyed, its tweet logs should go with it. The spec is already doing the right thing here, unlike the `has_one :github_integration` on `Account` which lacks `dependent: :destroy`. The spec even notes this inconsistency (Step 7) without introducing a new one. Correct approach.

No action needed.

---

## What Works Well

**The tool is 30 lines.** No action parameter, no dispatch, no `ACTIONS` constant, no `allowed_actions` in error responses. It does one thing and does it cleanly. This is exactly what was called for.

**The error handling is elegant.** A single `error(msg)` one-liner, `XApi::Error` catches everything, and the error messages are descriptive enough for an LLM to self-correct (character count in the length error, rate limit timing in the API error).

**The concern follows `GithubApi` precisely.** Single `Error` class, `encrypts` in the `included` block, `connected?` checks credentials, `disconnect!` clears them. The `post_tweet!` method is the only addition, and it encapsulates the API call + audit log creation in one bang method. Clean.

**The "Changes from v1a" table is excellent.** It documents every change and why, making the review traceable. This is the kind of spec hygiene that makes code review a pleasure.

**The "Key Design Decisions" section justifies every non-obvious choice.** Why no polymorphic dispatch, why a separate `TweetLog`, why no `posted_at`. Each justification is concise and correct.

**Test coverage is thorough.** Missing integration, disabled integration, disconnected integration, text too long, successful post, audit log creation, rate limits, auth errors, boundary case. Nine tests covering all the meaningful paths.

---

## Verdict

This spec is ready to implement. The v1a feedback was applied cleanly, no new issues were introduced, and the result is a focused, pattern-consistent implementation plan. The minor items noted above (model-level test for `post_tweet!`, runtime verification of `e.reset_in` behavior) are implementation-time concerns, not spec blockers.

Ship it.
