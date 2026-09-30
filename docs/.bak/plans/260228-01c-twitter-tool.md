# Twitter/X Posting Tool (v1)

## Executive Summary

Add the ability for Nexus agents to post tweets to X/Twitter. A single shared X account per Nexus account, with direct auto-posting and a full audit trail. Post-only for v1 -- no inbound mentions, DMs, or timeline reading.

The implementation follows the established integration pattern (mirroring `GithubIntegration` / `GithubApi` / `GithubCommitsTool`) but deliberately skips the polymorphic action dispatch since this tool only does one thing: post a tweet.

## Architecture Overview

```
Account
  has_one :x_integration          (credentials + enabled flag)

XIntegration
  belongs_to :account
  has_many :tweet_logs            (audit trail)
  encrypts :api_key, :api_key_secret, :access_token, :access_token_secret
  #post_tweet!(text, agent:) -> posts via `x` gem, creates TweetLog, returns result hash

TweetLog
  belongs_to :x_integration
  belongs_to :agent               (non-optional, null: false)
  stores tweet_id, text
  uses created_at for ordering    (no separate posted_at column)

TwitterTool < RubyLLM::Tool
  execute(text:) -> posts a tweet
  ~30 lines, no action dispatch
```

The `x` gem (sferik/x-ruby) handles the HTTP layer. All X API interaction is encapsulated in an `XApi` concern on `XIntegration`, following the `GithubApi` concern pattern.

## Implementation Plan

### Step 1: Add the `x` gem

- [ ] Add `gem "x"` to the Gemfile
- [ ] Run `bundle install`

```ruby
# Gemfile
gem "x"
```

### Step 2: Create the migration for `x_integrations`

- [ ] Generate migration: `rails generate migration CreateXIntegrations`

```ruby
class CreateXIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :x_integrations do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.text :api_key
      t.text :api_key_secret
      t.text :access_token
      t.text :access_token_secret
      t.string :x_username
      t.boolean :enabled, default: true, null: false
      t.timestamps
    end
  end
end
```

All four credential fields are `text` (same as `github_integrations.access_token`). Rails `encrypts` handles encryption at the application level. The unique index on `account_id` enforces one integration per account.

### Step 3: Create the migration for `tweet_logs`

- [ ] Generate migration: `rails generate migration CreateTweetLogs`

```ruby
class CreateTweetLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :tweet_logs do |t|
      t.references :x_integration, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.string :tweet_id, null: false
      t.text :text, null: false
      t.timestamps
    end

    add_index :tweet_logs, :tweet_id, unique: true
  end
end
```

No `posted_at` column. `created_at` captures exactly when the tweet was posted, which is all we need.

### Step 4: Create the `XApi` concern

- [ ] Create `/app/models/concerns/x_api.rb`

```ruby
require "x"

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
    raise Error, "Rate limited. Retry in #{e.reset_in || 900} seconds."
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
      access_token: access_token, access_token_secret: access_token_secret,
      base_url: "https://api.x.com/2/"
    )
  end

end
```

Key decisions:
- Single `XApi::Error` class, no custom `RateLimited` subclass. Rate limit context is folded into the error message string. Matches how `GithubApi` handles its errors with a single `Error` class.
- `{ text: text }.to_json` for the POST body, not manual string construction.
- The `x` gem returns a parsed Hash by default (documented in x-ruby gem docs: "By default responses are parsed into Ruby Hash and Array objects"). So `response.dig("data", "id")` is the one correct path -- no conditional `is_a?(Hash)` dance.
- `post_tweet!` creates the `TweetLog` as part of the same operation. If the API call succeeds but the log fails, the bang raises and the caller knows something went wrong.
- `disconnect!` mirrors `GithubIntegration#disconnect!` -- clears credentials, leaves `enabled` untouched.

### Step 5: Create the `XIntegration` model

- [ ] Create `/app/models/x_integration.rb`

```ruby
class XIntegration < ApplicationRecord

  include XApi

  belongs_to :account
  has_many :tweet_logs, dependent: :destroy

  validates :account_id, uniqueness: true

  scope :enabled, -> { where(enabled: true) }

end
```

Deliberately minimal. The `XApi` concern does the heavy lifting.

### Step 6: Create the `TweetLog` model

- [ ] Create `/app/models/tweet_log.rb`

```ruby
class TweetLog < ApplicationRecord

  belongs_to :x_integration
  belongs_to :agent

  validates :tweet_id, presence: true, uniqueness: true
  validates :text, presence: true

  scope :recent, -> { order(created_at: :desc) }

end
```

Simple audit record. `agent` is non-optional with `null: false` in the migration -- tweets are always posted by an agent. `recent` scope uses `created_at` instead of a redundant `posted_at`.

### Step 7: Update the `Account` model

- [ ] Add `has_one :x_integration` to `Account`

```ruby
# In app/models/account.rb, alongside the existing has_one :github_integration
has_one :x_integration
```

Note: `has_one :github_integration` also lacks `dependent: :destroy`. Both should probably have it, but that is a pre-existing issue -- not introducing a new inconsistency here.

### Step 8: Create the `TwitterTool`

- [ ] Create `/app/tools/twitter_tool.rb`

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

30 lines. No `action` parameter, no `ACTIONS` constant, no `send` dispatch. The tool does one thing: post a tweet. When v2 needs `delete` or `thread`, refactor to the polymorphic pattern then -- it takes 10 minutes.

Design notes:
- `MAX_TWEET_LENGTH` check before the API call prevents wasted requests and gives the LLM a self-correcting error with the exact character count.
- Single `error(msg)` helper, one-liner. Everything else is inline.
- `XApi::Error` catches both rate limits and API errors. The error message from `post_tweet!` already contains rate limit timing info.
- No `posted_at` in the response. The LLM does not need a timestamp to confirm a tweet was posted.

### Step 9: Create the `TwitterTool` test

- [ ] Create `/test/tools/twitter_tool_test.rb`

Tests use **VCR cassettes** to record real X API responses (no webmock stubs). The integration is configured with real credentials from `Rails.application.credentials.dig(:x, ...)` for the VCR recording pass. Subsequent runs use the recorded cassettes.

**Important**: The VCR tests that actually post tweets must also delete them immediately. The `post_and_delete_tweet` helper handles this.

```ruby
require "test_helper"
require "support/vcr_setup"

class TwitterToolTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:team_account)
    @chat = @account.chats.create!(model_id: "openai/gpt-4o")
    @agent = agents(:research_assistant)
  end

  # --- Validation tests (no API calls needed) ---

  test "returns error when no x integration configured" do
    result = build_tool.execute(text: "Hello world")

    assert_equal "error", result[:type]
    assert_match(/not configured/, result[:error])
  end

  test "returns error when integration is disabled" do
    create_integration(enabled: false)

    result = build_tool.execute(text: "Hello world")

    assert_equal "error", result[:type]
    assert_match(/not configured/, result[:error])
  end

  test "returns error when integration is not connected" do
    create_integration(api_key: nil, api_key_secret: nil, access_token: nil, access_token_secret: nil)

    result = build_tool.execute(text: "Hello world")

    assert_equal "error", result[:type]
    assert_match(/not configured/, result[:error])
  end

  test "returns error when text exceeds 280 characters" do
    create_integration

    result = build_tool.execute(text: "a" * 281)

    assert_equal "error", result[:type]
    assert_match(/281 chars/, result[:error])
    assert_match(/max 280/, result[:error])
  end

  # --- API tests (use VCR cassettes) ---

  test "posts tweet successfully" do
    integration = create_real_integration

    VCR.use_cassette("twitter_tool/post_tweet") do
      result = build_tool.execute(text: "Nexus test tweet #{Time.current.to_i}")

      assert_equal "tweet_posted", result[:type]
      assert result[:tweet_id].present?
      assert result[:text].present?
      assert_match(%r{https://x.com/}, result[:url])

      # Clean up: delete the tweet immediately
      delete_tweet!(integration, result[:tweet_id])
    end
  end

  test "post creates tweet log record" do
    integration = create_real_integration

    VCR.use_cassette("twitter_tool/post_creates_log") do
      assert_difference "TweetLog.count", 1 do
        result = build_tool.execute(text: "Nexus log test #{Time.current.to_i}")

        # Clean up
        delete_tweet!(integration, result[:tweet_id])
      end

      log = TweetLog.last
      assert log.tweet_id.present?
      assert log.text.present?
      assert_equal @agent, log.agent
      assert_equal integration, log.x_integration
    end
  end

  test "handles auth errors with bad credentials" do
    create_integration(api_key: "bad_key", api_key_secret: "bad_secret",
                       access_token: "bad_token", access_token_secret: "bad_token_secret")

    VCR.use_cassette("twitter_tool/auth_error") do
      result = build_tool.execute(text: "This should fail")

      assert_equal "error", result[:type]
      assert_match(/X API error/, result[:error])
    end
  end

  private

  def create_integration(**overrides)
    defaults = {
      account: @account,
      enabled: true,
      api_key: "test_api_key",
      api_key_secret: "test_api_key_secret",
      access_token: "test_access_token",
      access_token_secret: "test_access_token_secret",
      x_username: "test_user"
    }
    XIntegration.create!(**defaults.merge(overrides))
  end

  def create_real_integration
    creds = Rails.application.credentials
    XIntegration.create!(
      account: @account,
      enabled: true,
      api_key: creds.dig(:x, :api_key),
      api_key_secret: creds.dig(:x, :api_key_secret),
      access_token: creds.dig(:x, :access_token),
      access_token_secret: creds.dig(:x, :access_token_secret),
      x_username: creds.dig(:x, :username)
    )
  end

  def build_tool
    TwitterTool.new(chat: @chat, current_agent: @agent)
  end

  def delete_tweet!(integration, tweet_id)
    integration.send(:x_client).delete("tweets/#{tweet_id}")
  rescue => e
    Rails.logger.warn("Failed to delete test tweet #{tweet_id}: #{e.message}")
  end

end
```

Testing notes:
- Uses **VCR cassettes** to record real X API interactions (not webmock stubs).
- Validation tests (no integration, disabled, disconnected, text too long) don't hit the API.
- API tests use `create_real_integration` with credentials from Rails test credentials.
- Test tweets are deleted immediately after posting via `delete_tweet!` helper.
- VCR filters in `vcr_setup.rb` scrub all X credentials from cassettes before they hit git.

### Step 10: Create the `XIntegration` model test

- [ ] Create `/test/models/x_integration_test.rb`

```ruby
require "test_helper"
require "support/vcr_setup"

class XIntegrationTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:team_account)
  end

  test "validates uniqueness of account" do
    XIntegration.create!(account: @account, api_key: "k", api_key_secret: "ks", access_token: "t", access_token_secret: "ts")

    duplicate = XIntegration.new(account: @account, api_key: "k2", api_key_secret: "ks2", access_token: "t2", access_token_secret: "ts2")
    assert_not duplicate.valid?
  end

  test "connected? requires all four credentials" do
    integration = XIntegration.new(account: @account)
    assert_not integration.connected?

    integration.assign_attributes(api_key: "k", api_key_secret: "ks", access_token: "t", access_token_secret: "ts")
    assert integration.connected?
  end

  test "disconnect! clears all credentials" do
    integration = XIntegration.create!(
      account: @account,
      api_key: "k", api_key_secret: "ks",
      access_token: "t", access_token_secret: "ts",
      x_username: "bot"
    )

    integration.disconnect!
    integration.reload

    assert_nil integration.api_key
    assert_nil integration.access_token
    assert_nil integration.x_username
    assert_not integration.connected?
  end

  test "enabled scope returns only enabled integrations" do
    XIntegration.create!(account: @account, enabled: true, api_key: "k", api_key_secret: "ks", access_token: "t", access_token_secret: "ts")

    assert_equal 1, XIntegration.enabled.count
  end

  test "post_tweet! creates tweet log and returns result" do
    creds = Rails.application.credentials
    integration = XIntegration.create!(
      account: @account,
      api_key: creds.dig(:x, :api_key), api_key_secret: creds.dig(:x, :api_key_secret),
      access_token: creds.dig(:x, :access_token), access_token_secret: creds.dig(:x, :access_token_secret),
      x_username: creds.dig(:x, :username)
    )
    agent = agents(:research_assistant)

    VCR.use_cassette("x_integration/post_tweet") do
      result = integration.post_tweet!("Nexus model test #{Time.current.to_i}", agent: agent)

      assert result[:tweet_id].present?
      assert result[:text].present?
      assert_match(%r{https://x.com/}, result[:url])
      assert_equal 1, integration.tweet_logs.count

      log = integration.tweet_logs.last
      assert_equal result[:tweet_id], log.tweet_id
      assert_equal agent, log.agent

      # Clean up
      integration.send(:x_client).delete("tweets/#{result[:tweet_id]}") rescue nil
    end
  end

end
```

### Step 11: Admin UI for credential configuration

- [ ] Create `XIntegrationController`
- [ ] Create settings page at `app/frontend/pages/settings/x_integration.svelte`
- [ ] Add route to `config/routes.rb`

The admin UI is simpler than GitHub because there is no OAuth flow. Four credential fields, a username field, and an enabled toggle.

```ruby
# config/routes.rb (addition, alongside existing github_integration)
resource :x_integration, only: %i[show update destroy], controller: "x_integration"
```

```ruby
# app/controllers/x_integration_controller.rb
class XIntegrationController < ApplicationController

  def show
    integration = current_account.x_integration || current_account.build_x_integration

    render inertia: "settings/x_integration", props: {
      integration: integration_json(integration)
    }
  end

  def update
    integration = current_account.x_integration || current_account.build_x_integration
    integration.update!(integration_params)

    redirect_to x_integration_path, notice: "X integration updated"
  end

  def destroy
    current_account.x_integration&.disconnect!

    redirect_to x_integration_path, notice: "X integration disconnected"
  end

  private

  def integration_params
    params.require(:x_integration).permit(
      :api_key, :api_key_secret, :access_token, :access_token_secret,
      :x_username, :enabled
    )
  end

  def integration_json(integration)
    {
      id: integration.id,
      enabled: integration.enabled?,
      connected: integration.connected?,
      x_username: integration.x_username
    }
  end

end
```

The controller uses `build_x_integration` + `update!` in the `update` action, collapsing create-and-update into a single database write. No `create` action needed since there is no OAuth flow.

The Svelte settings page follows the pattern in `settings/github_integration.svelte` -- four password fields for credentials, a text field for the X username, and a toggle for enabled/disabled.

### Step 12: Run migrations and verify

- [ ] Run `rails db:migrate`
- [ ] Run `rails test`
- [ ] Run `bin/rubocop`
- [ ] Manually verify tool appears in agent tool configuration

## Implementation Notes

**Base URL override required.** The X API is now at `https://api.x.com/2/` but the x-ruby gem defaults to `https://api.twitter.com/2/`. The `x_client` method overrides this with `base_url: "https://api.x.com/2/"`.

**VCR cassettes for testing.** Tests use VCR to record real X API responses. On the first run, real tweets will be posted to @swombat and immediately deleted. Subsequent runs use the recorded cassettes. VCR filters in `vcr_setup.rb` must scrub all X API credentials from cassettes.

**Add VCR filters for X credentials.** Add these to `test/support/vcr_setup.rb`:
```ruby
config.filter_sensitive_data("<X_API_KEY>") { Rails.application.credentials.dig(:x, :api_key) }
config.filter_sensitive_data("<X_API_KEY_SECRET>") { Rails.application.credentials.dig(:x, :api_key_secret) }
config.filter_sensitive_data("<X_ACCESS_TOKEN>") { Rails.application.credentials.dig(:x, :access_token) }
config.filter_sensitive_data("<X_ACCESS_TOKEN_SECRET>") { Rails.application.credentials.dig(:x, :access_token_secret) }
```

**Delete test tweets immediately.** Every test that posts a tweet must delete it within the same VCR cassette. The `delete_tweet!` helper handles this gracefully.

## Key Design Decisions

### Why no polymorphic action dispatch

The polymorphic tool pattern exists to consolidate multiple related actions into a single tool to reduce LLM context bloat. A tool with one action and an `ACTIONS` array containing a single element is ceremony without purpose -- an extra parameter the LLM must provide every time, always with the same value. Ship what you need, refactor when you need more. Adding the polymorphic pattern later takes 10 minutes.

### Why `post_tweet!` lives on the model

Following the architecture's "fat models, skinny controllers" principle. The `XIntegration` model owns the X credentials and the relationship to `TweetLog`. Posting a tweet and logging it are inseparable business logic that belongs on the model.

### Why a separate `TweetLog` model instead of `AuditLog`

The existing `AuditLog` is designed for user-initiated browser actions (captures `ip_address`, `user_agent`, `Current.user`). Tweet posting happens via agent tool calls without HTTP context. A dedicated `TweetLog` provides proper associations (`belongs_to :agent`, `belongs_to :x_integration`), tweet-specific fields (`tweet_id`, `text`), and clean querying without filtering through unrelated audit data.

### Why no `posted_at` column

`posted_at` would always be `Time.current` at creation time, which is exactly what `created_at` captures. One less column, one less validation, one less thing to keep in sync.

### Why a single `XApi::Error` class

`GithubApi` uses a single `Error` class for all failure modes. Rate limit info is folded into the error message string. The tool catches `XApi::Error` and surfaces the message to the LLM. A custom `RateLimited` subclass would be over-engineering for v1.

## File Summary

| File | Action | Purpose |
|------|--------|---------|
| `Gemfile` | Modify | Add `gem "x"` |
| `db/migrate/XXXXXX_create_x_integrations.rb` | Create | X credentials table |
| `db/migrate/XXXXXX_create_tweet_logs.rb` | Create | Tweet audit log table |
| `app/models/concerns/x_api.rb` | Create | X API concern (post, disconnect, client) |
| `app/models/x_integration.rb` | Create | Integration model |
| `app/models/tweet_log.rb` | Create | Audit log model |
| `app/models/account.rb` | Modify | Add `has_one :x_integration` |
| `app/tools/twitter_tool.rb` | Create | Agent tool for posting tweets |
| `app/controllers/x_integration_controller.rb` | Create | Settings UI controller |
| `app/frontend/pages/settings/x_integration.svelte` | Create | Settings UI page |
| `config/routes.rb` | Modify | Add x_integration route |
| `test/tools/twitter_tool_test.rb` | Create | Tool tests |
| `test/models/x_integration_test.rb` | Create | Model tests |
