# Twitter Tool Spec -- DHH-Style Review

## Overall Assessment

This is a solid, well-structured spec that clearly understands the existing patterns and follows them faithfully. The author has done their homework -- the `XApi` concern mirrors `GithubApi`, the tool mirrors `GithubCommitsTool`, the controller mirrors `GithubIntegrationController`. That pattern-following instinct is exactly right.

That said, there are a handful of places where the spec introduces unnecessary complexity, deviates from how the existing code actually works, or over-engineers for a v1 that only does one thing. Let me be specific.

---

## Critical Issues

### 1. A single-action tool does not need the polymorphic action pattern

This is the biggest issue. The polymorphic tool pattern exists to **consolidate multiple related actions into a single tool** to reduce LLM context bloat. The spec itself says: "Only one action (`post`) for v1."

A tool with one action and an `ACTIONS` array containing a single element is ceremony without purpose. Look at what the `execute` method does:

```ruby
def execute(action:, text: nil)
  return validation_error("Invalid action '#{action}'") unless ACTIONS.include?(action)
  send("#{action}_action", text: text)
end
```

This dispatches to exactly one method. The `action` parameter adds nothing -- it is an extra parameter the LLM must provide every single time, always with the same value, to do the only thing the tool can do. That is the opposite of conceptual compression.

**Either:**
- (a) Drop the action parameter entirely. Make it `execute(text:)` and have the tool just post a tweet. When v2 adds `delete` or `thread`, refactor to the polymorphic pattern then. YAGNI.
- (b) If you are *certain* v2 actions are imminent, keep the pattern but be honest about the trade-off -- you are paying a complexity tax now for future extensibility.

Option (a) is what DHH would do. Ship what you need, refactor when you need more. The polymorphic pattern is trivial to add later.

### 2. The `post_tweet!` response parsing is fragile

```ruby
response = x_client.post("tweets", "{\"text\":#{text.to_json}}")
data = response.is_a?(Hash) ? response : JSON.parse(response.to_s)
```

That manual JSON string construction (`"{\"text\":#{text.to_json}}"`) is a code smell. If the `x` gem's `post` method accepts a hash body (which it does -- check the gem's README), this should just be:

```ruby
response = x_client.post("tweets", { text: text }.to_json)
```

And the `response.is_a?(Hash) ? response : JSON.parse(response.to_s)` conditional suggests uncertainty about what the gem returns. During implementation, pin this down. Don't write defensive code around an API you haven't tested -- verify the return type and write the one correct path.

### 3. The `TweetLog.agent` association is `null: false` in the migration but `optional: true` in the architecture diagram

The architecture overview says:

```
TweetLog
  belongs_to :agent, optional: true
```

But the migration says:

```ruby
t.references :agent, null: false, foreign_key: true
```

And the model says:

```ruby
belongs_to :agent
```

Pick one and be consistent. Given that tweets are always posted by an agent (that is the entire point of this tool), `null: false` with a non-optional `belongs_to` is correct. But the architecture diagram is lying about `optional: true`, and that will confuse the implementer.

---

## Improvements Needed

### 4. The error helper methods are over-specified for a tool this simple

Look at the existing tools. `GithubCommitsTool` defines its error helpers as one-liners:

```ruby
def validation_error(msg) = { type: "error", error: msg, allowed_actions: ACTIONS }
def param_error(action, param) = { type: "error", error: "#{param} is required for #{action}", allowed_actions: ACTIONS }
```

The spec's `TwitterTool` defines four separate multi-line error methods:

```ruby
def validation_error(msg)
  { type: "error", error: msg, allowed_actions: ACTIONS }
end

def param_error(action, param)
  { type: "error", error: "#{param} is required for #{action} action", action: action, required_param: param, allowed_actions: ACTIONS }
end

def length_error(text)
  { type: "error", error: "Tweet exceeds #{MAX_TWEET_LENGTH} characters (#{text.length}). Shorten the text and try again.", character_count: text.length, max_length: MAX_TWEET_LENGTH, allowed_actions: ACTIONS }
end

def integration_error
  { type: "error", error: "X/Twitter integration is not configured or not enabled for this account", allowed_actions: ACTIONS }
end
```

`integration_error` and `length_error` are single-use methods that exist only to construct a hash literal. They do not reduce duplication -- they scatter the logic. Inline them. The `length_error` in particular carries extra metadata (`character_count`, `max_length`) that is legitimately useful for the LLM, but it still does not need its own method. A direct return from `post_action` is clearer:

```ruby
def post_action(text:)
  return param_error("post", "text") if text.blank?

  if text.length > MAX_TWEET_LENGTH
    return validation_error("Tweet is #{text.length} characters (max #{MAX_TWEET_LENGTH}). Shorten and retry.")
  end

  integration = @chat&.account&.x_integration
  return validation_error("X integration not configured or not enabled") unless integration&.enabled? && integration&.connected?

  # ... post logic
end
```

Follow the `GithubCommitsTool` pattern: two one-liner helpers, everything else inline.

### 5. The `XApi::RateLimited` custom exception class is premature

The spec creates a custom exception hierarchy:

```ruby
class Error < StandardError; end
class RateLimited < Error
  attr_reader :reset_in
  def initialize(reset_in:)
    @reset_in = reset_in
    super("Rate limited. Retry in #{reset_in} seconds.")
  end
end
```

Compare this to `GithubApi`, which has exactly one error class:

```ruby
class Error < StandardError; end
```

GitHub's API also has rate limits. The `GithubApi` concern handles them inline without a custom exception:

```ruby
if response.code == "403" && response["X-RateLimit-Remaining"] == "0"
  Rails.logger.warn("GitHub rate limit hit for account #{account_id}")
  return nil
end
```

For v1 with one action, `XApi::Error` is sufficient. Put the rate limit context in the error message string. The tool can match on the message or the exception type (`X::TooManyRequests`) directly:

```ruby
rescue X::TooManyRequests => e
  reset_in = e.rate_limit&.reset_in || 900
  raise Error, "Rate limited. Retry in #{reset_in} seconds."
rescue X::Error => e
  raise Error, e.message
```

The tool catches `XApi::Error` regardless, and can include `retry_after` by parsing or by the concern returning a richer result hash. A custom exception subclass for a v1 feature is over-engineering.

### 6. The `disconnect!` method clears credentials but not `enabled`

```ruby
def disconnect!
  update!(
    api_key: nil,
    api_key_secret: nil,
    access_token: nil,
    access_token_secret: nil,
    x_username: nil
  )
end
```

After `disconnect!`, `enabled` remains `true` but `connected?` returns `false`. This is fine -- it mirrors `GithubIntegration.disconnect!` which also does not touch `enabled`. Consistent. No issue here, just noting for the implementer that this is intentional.

### 7. The controller's `update` action has a subtle create-then-update pattern

```ruby
def update
  integration = current_account.x_integration || current_account.create_x_integration!
  integration.update!(integration_params)

  redirect_to x_integration_path, notice: "X integration updated"
end
```

Compare to `GithubIntegrationController`, which uses `create` and `update` as separate actions with distinct responsibilities. The Twitter controller conflates creation and updating into a single `update` action. This is arguably simpler for a form-based credential entry (no OAuth), but the `create_x_integration!` followed immediately by `update!` is two database writes when one would do.

Use `find_or_initialize_by` instead:

```ruby
def update
  integration = current_account.x_integration || current_account.build_x_integration
  integration.update!(integration_params)

  redirect_to x_integration_path, notice: "X integration updated"
end
```

`build_x_integration` + `update!` collapses to a single save. Cleaner.

### 8. The `execute` method signature deviates from `GithubCommitsTool`

`GithubCommitsTool` uses `**params` splat and dispatches with `case`:

```ruby
def execute(action: "fetch", count: DEFAULT_COMMITS, sha: nil, path: nil)
  # ...
  case action
  when "fetch", "sync" then execute_commits(integration, action, count)
  when "diff"          then execute_diff(integration, sha)
  when "file"          then execute_file(integration, path)
  end
end
```

The spec's `TwitterTool` uses `send`:

```ruby
def execute(action:, text: nil)
  return validation_error("Invalid action '#{action}'") unless ACTIONS.include?(action)
  send("#{action}_action", text: text)
end
```

Both patterns exist in the codebase (`WhiteboardTool` uses `send`, `GithubCommitsTool` uses `case`). With a single action, the `send` dispatch is especially unnecessary. Just call the method directly. But if you keep the action pattern per point 1(b), either `case` or `send` is fine -- just be aware that `send` with user input requires the `ACTIONS.include?` guard (which the spec correctly has).

### 9. The `posted_at` column on `TweetLog` is redundant

```ruby
t.datetime :posted_at, null: false
t.timestamps
```

`posted_at` will always be `Time.current` at the moment of creation, which is exactly what `created_at` already captures. Unless you expect to backfill tweet logs with historical `posted_at` values that differ from `created_at`, this column is redundant.

The spec's `post_tweet!` method confirms this:

```ruby
tweet_logs.create!(
  agent: agent,
  tweet_id: tweet_id,
  text: text,
  posted_at: Time.current
)
```

`Time.current` at creation time is `created_at`. Drop `posted_at` and use `created_at`. One less column, one less validation, one less thing to keep in sync. The `recent` scope becomes `order(created_at: :desc)`, which is also the default Rails ordering.

### 10. Missing `dependent: :destroy` on `Account.has_one :x_integration`

The existing pattern:

```ruby
has_one :github_integration
```

also lacks `dependent: :destroy`, so the spec is consistent. But both are wrong. If an account is destroyed, its integration record should go with it. This is a pre-existing issue, not introduced by this spec, but worth noting.

---

## What Works Well

**Pattern adherence.** The spec mirrors the existing `GithubIntegration` / `GithubApi` / `GithubCommitsTool` triangle perfectly. The implementer will have a clear map to follow.

**Encryption.** Using Rails `encrypts` for all four OAuth 1.0a credentials is correct and idiomatic.

**Self-correcting errors.** The tool returns structured error responses with `allowed_actions` and context about what went wrong. This follows the polymorphic tool pattern documentation precisely.

**Audit trail design.** The `TweetLog` model as a dedicated audit record (rather than shoehorning into `AuditLog`) is the right call. The justification in the design decisions section is well-reasoned.

**Test coverage.** The tests are thorough and follow the existing `GithubCommitsToolTest` pattern. Using `webmock` for HTTP stubbing is consistent with the codebase. The boundary test (exactly 280 characters) is a nice touch.

**The `XApi` concern is clean.** The separation of API concerns into a concern module, with the model staying deliberately minimal, follows the established pattern well.

**Scope discipline.** Post-only for v1, no inbound mentions, no DMs, no timeline reading. This is exactly the right instinct -- ship the smallest useful thing.

---

## Refactored Version

If I were writing this spec, here is what the tool would look like for a v1 that only posts tweets. No action parameter, no dispatch, no ceremony.

```ruby
class TwitterTool < RubyLLM::Tool

  MAX_TWEET_LENGTH = 280

  description "Post a tweet to X/Twitter."

  param :text, type: :string,
        desc: "Tweet text (max 280 characters)",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(text:)
    return error("Tweet is #{text.length} chars (max #{MAX_TWEET_LENGTH}). Shorten and retry.") if text.length > MAX_TWEET_LENGTH

    integration = @chat&.account&.x_integration
    return error("X integration not configured or not enabled") unless integration&.enabled? && integration&.connected?

    result = integration.post_tweet!(text, agent: @current_agent)

    { type: "tweet_posted", tweet_id: result[:tweet_id], text: result[:text], url: result[:url] }
  rescue XApi::Error => e
    error("X API error: #{e.message}")
  end

  private

  def error(msg) = { type: "error", error: msg }

end
```

That is 30 lines. It does exactly one thing. When v2 needs `delete` or `thread`, refactor to the polymorphic pattern -- it takes 10 minutes.

The `XApi` concern simplifies similarly without the custom `RateLimited` subclass:

```ruby
module XApi
  extend ActiveSupport::Concern

  class Error < StandardError; end

  included do
    encrypts :api_key, :api_key_secret, :access_token, :access_token_secret
  end

  def connected?
    [api_key, api_key_secret, access_token, access_token_secret].all?(&:present?)
  end

  def post_tweet!(text, agent:)
    raise Error, "X integration not connected" unless connected?

    response = x_client.post("tweets", { text: text }.to_json)
    tweet_id = response.dig("data", "id")
    raise Error, "No tweet ID returned" unless tweet_id

    tweet_logs.create!(agent: agent, tweet_id: tweet_id, text: text)

    { tweet_id: tweet_id, text: text, url: "https://x.com/#{x_username}/status/#{tweet_id}" }
  rescue X::TooManyRequests => e
    raise Error, "Rate limited. Retry in #{e.rate_limit&.reset_in || 900} seconds."
  rescue X::Error => e
    raise Error, e.message
  end

  def disconnect!
    update!(api_key: nil, api_key_secret: nil, access_token: nil, access_token_secret: nil, x_username: nil)
  end

  private

  def x_client
    @x_client ||= X::Client.new(
      api_key: api_key, api_key_secret: api_key_secret,
      access_token: access_token, access_token_secret: access_token_secret
    )
  end
end
```

And the `TweetLog` drops `posted_at`:

```ruby
class TweetLog < ApplicationRecord
  belongs_to :x_integration
  belongs_to :agent

  validates :tweet_id, presence: true, uniqueness: true
  validates :text, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
```

---

## Summary of Changes

| Issue | Severity | Recommendation |
|-------|----------|----------------|
| Single-action tool uses polymorphic dispatch | High | Drop `action` param for v1, just `execute(text:)` |
| Manual JSON string construction in `post_tweet!` | Medium | Use hash + `.to_json` |
| `optional: true` inconsistency on `TweetLog.agent` | Medium | Fix diagram to match migration (`null: false`) |
| Four separate error helper methods | Low | Two one-liner helpers max, inline the rest |
| `RateLimited` custom exception subclass | Low | Fold into `Error` with a descriptive message |
| `posted_at` column redundant with `created_at` | Low | Drop `posted_at`, use `created_at` |
| Controller `create_x_integration!` then `update!` | Low | Use `build_x_integration` + `update!` |

The spec is 80% there. The architecture is sound, the pattern following is disciplined, and the scope is right. The main issue is a tension between "follow the polymorphic tool pattern" and "this tool only does one thing." Resolve that tension in favor of simplicity and the spec becomes tight.
