# Twitter/X Posting Tool

## Executive Summary

Add the ability for Nexus agents to post tweets to X/Twitter. A single shared X account per Nexus account, with direct auto-posting (no approval queue) and a full audit trail. Post-only for v1 -- no inbound mentions, DMs, or timeline reading.

The implementation follows the established integration pattern (mirroring `GithubIntegration`) and the polymorphic domain tool pattern (mirroring `GithubCommitsTool` and `WebTool`).

## Architecture Overview

```
Account
  has_one :x_integration          (credentials + enabled flag)

XIntegration
  belongs_to :account
  has_many :tweet_logs            (audit trail)
  encrypts :api_key, :api_key_secret, :access_token, :access_token_secret
  #post_tweet!(text) -> posts via `x` gem, creates TweetLog, returns response

TweetLog
  belongs_to :x_integration
  belongs_to :agent, optional: true
  stores tweet_id, text, posted_at

TwitterTool < RubyLLM::Tool
  actions: post
  looks up account.x_integration via @chat.account
  calls x_integration.post_tweet!(text, agent: @current_agent)
  returns type-discriminated response
```

The `x` gem (sferik/x-ruby) handles the HTTP layer. All X API interaction is encapsulated in an `XApi` concern on `XIntegration`, following the `GithubApi` concern pattern. The tool itself stays under 60 lines.

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
      t.datetime :posted_at, null: false
      t.timestamps
    end

    add_index :tweet_logs, :tweet_id, unique: true
    add_index :tweet_logs, :posted_at
  end
end
```

### Step 4: Create the `XApi` concern

- [ ] Create `/app/models/concerns/x_api.rb`

Following the `GithubApi` pattern: the concern encapsulates all X API interaction, encrypts credentials, and provides a clean interface for posting.

```ruby
require "x"

module XApi

  extend ActiveSupport::Concern

  class Error < StandardError; end
  class RateLimited < Error
    attr_reader :reset_in
    def initialize(reset_in:)
      @reset_in = reset_in
      super("Rate limited. Retry in #{reset_in} seconds.")
    end
  end

  included do
    encrypts :api_key, :api_key_secret, :access_token, :access_token_secret
  end

  def connected?
    [api_key, api_key_secret, access_token, access_token_secret].all?(&:present?)
  end

  def post_tweet!(text, agent:)
    raise Error, "X integration not connected" unless connected?

    response = x_client.post("tweets", "{\"text\":#{text.to_json}}")
    data = response.is_a?(Hash) ? response : JSON.parse(response.to_s)
    tweet_id = data.dig("data", "id")

    raise Error, "No tweet ID returned" unless tweet_id

    tweet_logs.create!(
      agent: agent,
      tweet_id: tweet_id,
      text: text,
      posted_at: Time.current
    )

    { tweet_id: tweet_id, text: text, url: "https://x.com/#{x_username}/status/#{tweet_id}" }
  rescue X::TooManyRequests => e
    raise RateLimited.new(reset_in: e.rate_limit&.reset_in || 900)
  rescue X::Error => e
    raise Error, e.message
  end

  def disconnect!
    update!(
      api_key: nil,
      api_key_secret: nil,
      access_token: nil,
      access_token_secret: nil,
      x_username: nil
    )
  end

  private

  def x_client
    @x_client ||= X::Client.new(
      api_key: api_key,
      api_key_secret: api_key_secret,
      access_token: access_token,
      access_token_secret: access_token_secret
    )
  end

end
```

Key design decisions:
- `post_tweet!` creates the `TweetLog` as part of the same operation -- the audit record is inseparable from the post. If the API call succeeds but the log fails, the bang method raises and the caller knows something went wrong.
- The `x` gem's `X::TooManyRequests` is caught and re-raised as a domain-specific `RateLimited` error with `reset_in` context, so the tool can provide a useful self-correcting message.
- All other `X::Error` subtypes (`Unauthorized`, `Forbidden`, etc.) are caught and re-raised as the generic `XApi::Error`.

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

Deliberately minimal. The `XApi` concern does the heavy lifting, and the model stays clean. No additional business logic needed for v1.

### Step 6: Create the `TweetLog` model

- [ ] Create `/app/models/tweet_log.rb`

```ruby
class TweetLog < ApplicationRecord

  belongs_to :x_integration
  belongs_to :agent

  validates :tweet_id, presence: true, uniqueness: true
  validates :text, presence: true
  validates :posted_at, presence: true

  scope :recent, -> { order(posted_at: :desc) }

end
```

Simple audit record. The `agent` association tells you which agent posted the tweet. The `x_integration` association gives you the account context. The `tweet_id` uniqueness constraint prevents duplicate log entries.

### Step 7: Update the `Account` model

- [ ] Add `has_one :x_integration` to `Account`

```ruby
# In app/models/account.rb, alongside the existing has_one :github_integration
has_one :x_integration
```

### Step 8: Create the `TwitterTool`

- [ ] Create `/app/tools/twitter_tool.rb`

```ruby
class TwitterTool < RubyLLM::Tool

  ACTIONS = %w[post].freeze
  MAX_TWEET_LENGTH = 280

  description "Post tweets to X/Twitter. Actions: post."

  param :action, type: :string,
        desc: "post",
        required: true

  param :text, type: :string,
        desc: "Tweet text (max 280 characters)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(action:, text: nil)
    return validation_error("Invalid action '#{action}'") unless ACTIONS.include?(action)

    send("#{action}_action", text: text)
  end

  private

  def post_action(text:)
    return param_error("post", "text") if text.blank?
    return length_error(text) if text.length > MAX_TWEET_LENGTH

    integration = @chat&.account&.x_integration
    return integration_error unless integration&.enabled? && integration&.connected?

    result = integration.post_tweet!(text, agent: @current_agent)

    {
      type: "tweet_posted",
      tweet_id: result[:tweet_id],
      text: result[:text],
      url: result[:url],
      posted_at: Time.current.iso8601
    }
  rescue XApi::RateLimited => e
    { type: "error", error: "Rate limited. Try again in #{e.reset_in} seconds.", retry_after: e.reset_in }
  rescue XApi::Error => e
    { type: "error", error: "X API error: #{e.message}", allowed_actions: ACTIONS }
  end

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

end
```

Design notes:
- The tool is ~65 lines, well under the 100-line limit.
- The `MAX_TWEET_LENGTH` check is done at the tool level before hitting the API. This prevents wasted API calls and provides a self-correcting error that tells the LLM exactly how many characters it used and the limit.
- Rate limit errors include `retry_after` for the LLM to know how long to wait.
- The `integration_error` tells the agent clearly that the integration is not set up, so it can inform the user instead of retrying.
- Only one action (`post`) for v1. The `ACTIONS` array and the pattern make it trivial to add `delete` or `thread` later.

### Step 9: Create the test for `TwitterTool`

- [ ] Create `/test/tools/twitter_tool_test.rb`

```ruby
require "test_helper"
require "webmock/minitest"

class TwitterToolTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:team_account)
    @chat = @account.chats.create!(model_id: "openai/gpt-4o")
    @agent = agents(:research_assistant)
  end

  test "returns error for invalid action" do
    result = build_tool.execute(action: "invalid")

    assert_equal "error", result[:type]
    assert_match(/Invalid action/, result[:error])
    assert_equal %w[post], result[:allowed_actions]
  end

  test "returns error when no x integration configured" do
    result = build_tool.execute(action: "post", text: "Hello world")

    assert_equal "error", result[:type]
    assert_match(/not configured/, result[:error])
  end

  test "returns error when integration is disabled" do
    create_integration(enabled: false)

    result = build_tool.execute(action: "post", text: "Hello world")

    assert_equal "error", result[:type]
    assert_match(/not configured/, result[:error])
  end

  test "returns error when integration is not connected" do
    create_integration(api_key: nil, api_key_secret: nil, access_token: nil, access_token_secret: nil)

    result = build_tool.execute(action: "post", text: "Hello world")

    assert_equal "error", result[:type]
    assert_match(/not configured/, result[:error])
  end

  test "returns param error when text is blank" do
    create_integration

    result = build_tool.execute(action: "post")

    assert_equal "error", result[:type]
    assert_match(/text is required/, result[:error])
    assert_equal "text", result[:required_param]
  end

  test "returns length error when text exceeds 280 characters" do
    create_integration

    long_text = "a" * 281
    result = build_tool.execute(action: "post", text: long_text)

    assert_equal "error", result[:type]
    assert_match(/exceeds 280 characters/, result[:error])
    assert_equal 281, result[:character_count]
    assert_equal 280, result[:max_length]
  end

  test "posts tweet successfully" do
    create_integration

    stub_request(:post, "https://api.twitter.com/2/tweets")
      .to_return(
        status: 201,
        body: { data: { id: "1234567890", text: "Hello from Nexus" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = build_tool.execute(action: "post", text: "Hello from Nexus")

    assert_equal "tweet_posted", result[:type]
    assert_equal "1234567890", result[:tweet_id]
    assert_equal "Hello from Nexus", result[:text]
    assert_match(%r{https://x.com/.*/status/1234567890}, result[:url])
    assert result[:posted_at].present?
  end

  test "post creates tweet log record" do
    integration = create_integration

    stub_request(:post, "https://api.twitter.com/2/tweets")
      .to_return(
        status: 201,
        body: { data: { id: "9876543210", text: "Logged tweet" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    assert_difference "TweetLog.count", 1 do
      build_tool.execute(action: "post", text: "Logged tweet")
    end

    log = TweetLog.last
    assert_equal "9876543210", log.tweet_id
    assert_equal "Logged tweet", log.text
    assert_equal @agent, log.agent
    assert_equal integration, log.x_integration
  end

  test "handles rate limit errors" do
    create_integration

    stub_request(:post, "https://api.twitter.com/2/tweets")
      .to_return(
        status: 429,
        body: { detail: "Too Many Requests" }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "x-rate-limit-reset" => (Time.current + 900).to_i.to_s
        }
      )

    result = build_tool.execute(action: "post", text: "Rate limited tweet")

    assert_equal "error", result[:type]
    assert_match(/rate limit/i, result[:error])
  end

  test "handles auth errors" do
    create_integration

    stub_request(:post, "https://api.twitter.com/2/tweets")
      .to_return(
        status: 401,
        body: { detail: "Unauthorized" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = build_tool.execute(action: "post", text: "Unauthorized tweet")

    assert_equal "error", result[:type]
    assert_match(/X API error/, result[:error])
  end

  test "allows tweets at exactly 280 characters" do
    create_integration

    text = "a" * 280
    stub_request(:post, "https://api.twitter.com/2/tweets")
      .to_return(
        status: 201,
        body: { data: { id: "280tweet", text: text } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = build_tool.execute(action: "post", text: text)

    assert_equal "tweet_posted", result[:type]
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
      x_username: "nexus_bot"
    }
    XIntegration.create!(**defaults.merge(overrides))
  end

  def build_tool
    TwitterTool.new(chat: @chat, current_agent: @agent)
  end

end
```

Testing notes:
- Uses `webmock` for HTTP stubbing (consistent with `WebToolTest` pattern).
- No mocks, stubs, or fake objects per project rules. The `webmock` HTTP stubs are the permitted exception.
- Tests cover: invalid actions, missing integration, disabled integration, disconnected integration, missing text, text too long, successful post, audit log creation, rate limits, auth errors, boundary (exactly 280 chars).
- The exact URL stubbed (`https://api.twitter.com/2/tweets`) may need adjustment based on how the `x` gem constructs its requests. Verify against the gem's source during implementation.

### Step 10: Create the `XIntegration` model test

- [ ] Create `/test/models/x_integration_test.rb`

```ruby
require "test_helper"
require "webmock/minitest"

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

end
```

### Step 11: Admin UI for credential configuration (brief)

- [ ] Create `XIntegrationController` (following `GithubIntegrationController` pattern)
- [ ] Create settings page at `app/frontend/pages/settings/x_integration.svelte`
- [ ] Add route: `resource :x_integration, only: %i[show update destroy], controller: "x_integration"`

The admin UI is simpler than GitHub because there is no OAuth flow. It is a form with four credential fields and an enabled toggle. The controller follows the existing pattern.

```ruby
# config/routes.rb (addition)
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
    integration = current_account.x_integration || current_account.create_x_integration!
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

The Svelte settings page is a straightforward form -- four password fields for credentials, a text field for the X username, and a toggle for enabled/disabled. Follow the pattern in `settings/github_integration.svelte`.

### Step 12: Run migrations and verify

- [ ] Run `rails db:migrate`
- [ ] Run `rails test`
- [ ] Run `bin/rubocop`
- [ ] Manually verify tool appears in `Agent.available_tools`

## Key Design Decisions

### Why `post_tweet!` lives on the model, not in a service object

Following the architecture doc's "fat models, skinny controllers" principle. The `XIntegration` model owns the X credentials and the relationship to `TweetLog`. Posting a tweet and logging it are inseparable business logic that belongs on the model.

### Why a separate `TweetLog` model instead of using `AuditLog`

The existing `AuditLog` is designed for user-initiated browser actions (it captures `ip_address`, `user_agent`, and `Current.user`). Tweet posting happens in background jobs without HTTP context. A dedicated `TweetLog` model provides:
- Proper associations (`belongs_to :agent`, `belongs_to :x_integration`)
- Tweet-specific fields (`tweet_id`, `text`, `posted_at`)
- Easy querying for tweet history without filtering through unrelated audit data
- Clean separation of concerns

The `AuditLog` can still be used when an admin changes X integration settings via the UI.

### Why `MAX_TWEET_LENGTH` validation in the tool

Catching length violations before the API call saves a network round-trip and provides a better self-correcting error. The LLM gets the exact character count and limit, making it trivial to retry with a shorter text.

### Why encrypt all four credential fields

All four OAuth 1.0a values are sensitive. If any one is compromised, an attacker can impersonate the account. Rails `encrypts` provides transparent encryption at rest with minimal code.

### Why only `post` action for v1

Keeping the tool minimal for v1. The pattern supports easy extension:
- `delete` action: pass a `tweet_id`, call `x_client.delete("tweets/#{tweet_id}")`
- `thread` action: pass an `in_reply_to_tweet_id` alongside `text`
- `status` action: check rate limit status without posting

These can be added to `ACTIONS` and as private methods without touching existing code.

## Future Considerations

### v2: Thread support
Add `reply_to_tweet_id` parameter to the `post` action. The X API supports `reply.in_reply_to_tweet_id` in the POST payload. The `TweetLog` could gain a `parent_tweet_id` column to track threads.

### v2: Rate limit awareness
Add a `status` action that returns remaining posts in the current window. The `x` gem exposes rate limit headers. Store last-known limits on the integration model.

### v2: Inbound mentions
Add a polling job (like `SyncGithubCommitsJob`) that checks for mentions periodically and injects them into agent conversations.

### v2: Media attachments
The X API supports media uploads. This would require a two-step process (upload media, then post tweet with media_id) but the tool pattern accommodates it naturally.

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
