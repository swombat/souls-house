# DHH Review: Oura Ring Integration Spec

**Reviewer**: DHH-style review
**Date**: 2026-01-27
**Verdict**: Solid foundation, but over-engineered in places. Needs simplification.

---

## Overall Assessment

This spec demonstrates a good grasp of Rails conventions - no service objects, business logic in the model, thin controller. However, it falls into the trap of building for hypothetical future requirements rather than the actual problem at hand. The model is bloated with OAuth ceremony that could be extracted more elegantly, the column naming is awkward, and there are several unnecessary features that add complexity without clear value.

The core idea is sound: store Oura tokens, sync health data, inject into system prompts. But the implementation has accumulated cruft that a first version doesn't need.

---

## Critical Issues

### 1. Awkward Column Naming: `access_token_ciphertext`

```ruby
t.text :access_token_ciphertext
t.text :refresh_token_ciphertext
```

This is fighting Rails encryption. When you use `encrypts :access_token`, Rails handles the ciphertext column naming automatically. The convention is:

```ruby
# Migration
t.text :access_token
t.text :refresh_token

# Model
encrypts :access_token
encrypts :refresh_token
```

Rails will store encrypted values in `access_token` directly. The `_ciphertext` suffix is an implementation detail you're exposing unnecessarily. It also makes the code confusing when you later write `access_token_ciphertext` everywhere instead of just `access_token`.

### 2. OAuth State Stored in the Same Model

Storing `oauth_state` and `oauth_state_expires_at` in the permanent `OuraIntegration` record is mixing concerns. OAuth state is ephemeral - it exists only during the OAuth flow and should be discarded immediately after. Consider:

- Using Rails `session` for OAuth state (the natural place for ephemeral flow data)
- Or a simple `SecureRandom.hex(32)` that lives only for the duration of the redirect

The current design leaves stale `oauth_state` values lying around in the database forever.

### 3. Premature Scope-Based Control

```ruby
t.string :scopes, array: true, default: []
```

Are you actually going to conditionally request different scopes based on user preference? No. You always request the same scopes (`REQUESTED_SCOPES`). This column exists for a hypothetical future where users might grant partial access. YAGNI.

Delete it. If you need it later, add it later.

### 4. Granular Sharing Toggles: Are They Needed?

```ruby
t.boolean :share_sleep, default: true, null: false
t.boolean :share_readiness, default: true, null: false
t.boolean :share_activity, default: true, null: false
```

Three separate toggles for three data types. But ask yourself: what user is going to connect their Oura Ring and then say "I want to share my sleep but NOT my readiness"? This feels like checkbox-driven design.

A single `enabled` toggle is likely sufficient for v1. If users actually request granular control, add it then. Right now it's:
- More UI complexity
- More columns
- More code paths to test
- Zero proven user value

### 5. The Model Is Too Fat

The `OuraIntegration` model has become a dumping ground:
- OAuth URL generation
- Token exchange
- Token refresh
- API calls to three different endpoints
- Data formatting for system prompts
- Time formatting helpers
- HTTP client configuration

This is "fat model" taken too far. The Rails philosophy is "fat models, skinny controllers" - not "obese models that do everything."

Consider extracting the HTTP/API concerns into a simple module or even keeping them in the model but grouping them better. The formatting methods (`format_sleep_context`, etc.) are fine in the model since they're about presenting the model's data.

---

## Improvements Needed

### 1. Simplify the Schema

```ruby
# Before - over-engineered
create_table :oura_integrations do |t|
  t.references :user, null: false, foreign_key: true, index: { unique: true }
  t.text :access_token_ciphertext
  t.text :refresh_token_ciphertext
  t.datetime :token_expires_at
  t.string :scopes, array: true, default: []
  t.jsonb :health_data, default: {}
  t.datetime :health_data_synced_at
  t.boolean :enabled, default: true, null: false
  t.boolean :share_sleep, default: true, null: false
  t.boolean :share_readiness, default: true, null: false
  t.boolean :share_activity, default: true, null: false
  t.string :oauth_state
  t.datetime :oauth_state_expires_at
  t.timestamps
end

# After - what you actually need
create_table :oura_integrations do |t|
  t.references :user, null: false, foreign_key: true, index: { unique: true }
  t.text :access_token
  t.text :refresh_token
  t.datetime :token_expires_at
  t.jsonb :health_data, default: {}
  t.datetime :health_data_synced_at
  t.boolean :enabled, default: true, null: false
  t.timestamps
end
```

Seven columns removed. You can always add granular sharing toggles and scopes tracking later if users actually need them.

### 2. Use Session for OAuth State

```ruby
# Controller
def create
  state = SecureRandom.hex(32)
  session[:oura_oauth_state] = state
  session[:oura_oauth_state_expires_at] = 10.minutes.from_now.to_i

  integration = Current.user.oura_integration || Current.user.create_oura_integration!
  redirect_to integration.authorization_url(state: state, redirect_uri: callback_url),
              allow_other_host: true
end

def callback
  expected_state = session.delete(:oura_oauth_state)
  expires_at = session.delete(:oura_oauth_state_expires_at)

  unless expected_state == params[:state] && Time.current.to_i < expires_at.to_i
    redirect_to oura_integrations_path, alert: "Invalid authorization"
    return
  end
  # ... proceed with token exchange
end
```

The model doesn't need to know about OAuth state at all.

### 3. The Model Should Accept State, Not Generate It

```ruby
# Before - model generates and stores state
def authorization_url(redirect_uri:)
  self.oauth_state = SecureRandom.hex(32)
  self.oauth_state_expires_at = 10.minutes.from_now
  save!
  # ...
end

# After - model just builds the URL
def authorization_url(state:, redirect_uri:)
  params = {
    response_type: "code",
    client_id: oura_client_id,
    redirect_uri: redirect_uri,
    scope: REQUESTED_SCOPES.join(" "),
    state: state
  }
  "#{OURA_AUTHORIZE_URL}?#{params.to_query}"
end
```

State management is a controller concern (session management). The model should be stateless for this operation.

### 4. Context Injection Location Is Wrong

```ruby
# Proposed in spec - adding to Chat model
def user_health_context
  recent_user = messages.where.not(user_id: nil)
                        .order(created_at: :desc)
                        .limit(1)
                        .pick(:user_id)
  return nil unless recent_user
  User.find(recent_user).oura_health_context
end
```

This is convoluted. The Chat model is doing an N+1 dance to find a user just to get health context.

Better approach: the system message already has access to the user via the message context. The health context should be fetched once and passed in, or accessed through the account (since this is an account-scoped chat):

```ruby
# Simpler - account owner's health context
def user_health_context
  account.owner&.oura_health_context
end
```

Or even better, don't add this to Chat at all. The `system_message_for` method already builds context. Just add health context there directly:

```ruby
def system_message_for(agent)
  parts = []
  # ... existing parts ...

  if (health_context = account.owner&.oura_health_context)
    parts << health_context
  end

  # ...
end
```

No new private method needed.

### 5. Error Class Definition Location

```ruby
class OuraApiError < StandardError; end
```

This is defined at the bottom of the model file, outside the class. In Rails, custom errors like this should either be:
- Inside the model class (if truly model-specific)
- In a dedicated errors file if reused

```ruby
class OuraIntegration < ApplicationRecord
  class ApiError < StandardError; end
  # ...
end

# Usage
rescue OuraIntegration::ApiError
```

### 6. The `disconnect!` Method Does Too Much

```ruby
def disconnect!
  if access_token_ciphertext.present?
    HTTParty.get("https://api.ouraring.com/oauth/revoke?access_token=#{access_token_ciphertext}")
  rescue StandardError => e
    Rails.logger.warn("Failed to revoke Oura token: #{e.message}")
  end

  update!(
    access_token_ciphertext: nil,
    refresh_token_ciphertext: nil,
    # ... 8 more fields
  )
end
```

Token revocation is a nice-to-have but shouldn't block disconnection. Also, rescuing `StandardError` is too broad. The current approach is fine, but consider:

```ruby
def disconnect!
  revoke_token_silently
  clear_connection!
end

private

def revoke_token_silently
  return unless access_token.present?
  HTTParty.get("#{OURA_API_BASE}/oauth/revoke", query: { access_token: access_token })
rescue StandardError => e
  Rails.logger.warn("Oura token revocation failed: #{e.message}")
end

def clear_connection!
  update!(access_token: nil, refresh_token: nil, token_expires_at: nil, health_data: {}, health_data_synced_at: nil)
end
```

### 7. Route Design Inconsistency

```ruby
resource :oura_integrations, only: [:show, :create, :update, :destroy] do
  get :callback, on: :collection
  post :sync, on: :member
end
```

Using `resource` (singular) with a plural name `oura_integrations` is confusing. Since there's only one per user, use singular:

```ruby
resource :oura_integration, only: [:show, :create, :update, :destroy] do
  get :callback, on: :collection
  post :sync, on: :member
end
```

This gives you `/oura_integration` instead of `/oura_integrations` - cleaner for a singular resource.

---

## What Works Well

1. **No Service Objects**: Business logic stays in the model. This is correct.

2. **Association-Based Authorization**: `Current.user.oura_integration` naturally scopes access. No authorization gem needed.

3. **Background Job Design**: `SyncOuraDataJob` is simple and appropriate. The retry strategy is sensible.

4. **Encrypted Tokens**: Using Rails encryption for OAuth tokens is the right call.

5. **Health Context Formatting**: The `format_*_context` methods are well-structured and produce clean Markdown output.

6. **Test Coverage Plan**: The spec includes comprehensive model and controller tests.

---

## Refactored Version

Here's a cleaner model that ships the MVP:

```ruby
# app/models/oura_integration.rb
class OuraIntegration < ApplicationRecord
  class ApiError < StandardError; end

  OURA_AUTHORIZE_URL = "https://cloud.ouraring.com/oauth/authorize"
  OURA_TOKEN_URL = "https://api.ouraring.com/oauth/token"
  OURA_API_BASE = "https://api.ouraring.com/v2"
  SCOPES = %w[email personal daily heartrate].freeze

  belongs_to :user

  encrypts :access_token
  encrypts :refresh_token

  validates :user_id, uniqueness: true

  scope :enabled, -> { where(enabled: true) }
  scope :needs_sync, -> { enabled.where("health_data_synced_at IS NULL OR health_data_synced_at < ?", 6.hours.ago) }
  scope :with_valid_tokens, -> { where("token_expires_at > ?", Time.current) }

  def authorization_url(state:, redirect_uri:)
    params = {
      response_type: "code",
      client_id: credentials(:client_id),
      redirect_uri: redirect_uri,
      scope: SCOPES.join(" "),
      state: state
    }
    "#{OURA_AUTHORIZE_URL}?#{params.to_query}"
  end

  def exchange_code!(code:, redirect_uri:)
    response = HTTParty.post(OURA_TOKEN_URL, body: {
      grant_type: "authorization_code",
      code: code,
      client_id: credentials(:client_id),
      client_secret: credentials(:client_secret),
      redirect_uri: redirect_uri
    })

    save_tokens!(response)
  end

  def connected?
    access_token.present? && token_expires_at&.future?
  end

  def sync_health_data!
    refresh_tokens_if_needed!
    return unless connected?

    update!(
      health_data: fetch_all_health_data,
      health_data_synced_at: Time.current
    )
  end

  def health_context
    return unless enabled? && health_data.present?

    parts = [
      format_sleep_context,
      format_readiness_context,
      format_activity_context
    ].compact

    return if parts.empty?

    "# Health Data from Oura Ring\n\n#{parts.join("\n\n")}"
  end

  def disconnect!
    revoke_token_silently
    update!(access_token: nil, refresh_token: nil, token_expires_at: nil,
            health_data: {}, health_data_synced_at: nil)
  end

  private

  def credentials(key)
    Rails.application.credentials.dig(:oura, key) ||
      raise(ArgumentError, "Oura #{key} not configured")
  end

  def save_tokens!(response)
    raise ApiError, "Token exchange failed: #{response.code}" unless response.success?

    data = JSON.parse(response.body)
    update!(
      access_token: data["access_token"],
      refresh_token: data["refresh_token"],
      token_expires_at: data["expires_in"].to_i.seconds.from_now
    )
  end

  def refresh_tokens_if_needed!
    return if token_expires_at && token_expires_at > 1.day.from_now

    response = HTTParty.post(OURA_TOKEN_URL, body: {
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: credentials(:client_id),
      client_secret: credentials(:client_secret)
    })

    save_tokens!(response)
  end

  def fetch_all_health_data
    today = Date.current
    yesterday = today - 1.day

    {
      sleep: fetch_endpoint("/usercollection/daily_sleep", yesterday, today),
      readiness: fetch_endpoint("/usercollection/daily_readiness", yesterday, today),
      activity: fetch_endpoint("/usercollection/daily_activity", yesterday, today)
    }
  end

  def fetch_endpoint(path, start_date, end_date)
    response = HTTParty.get("#{OURA_API_BASE}#{path}",
      headers: { "Authorization" => "Bearer #{access_token}" },
      query: { start_date: start_date.to_s, end_date: end_date.to_s }
    )

    return nil unless response.success?
    JSON.parse(response.body)["data"]
  rescue StandardError => e
    Rails.logger.error("Oura API error: #{e.message}")
    nil
  end

  def revoke_token_silently
    return unless access_token.present?
    HTTParty.get("https://api.ouraring.com/oauth/revoke", query: { access_token: access_token })
  rescue StandardError
    # Token revocation is best-effort
  end

  def format_sleep_context
    latest = health_data.dig("sleep")&.max_by { |d| d["day"] }
    return unless latest

    score = latest["score"]
    c = latest["contributors"] || {}

    lines = ["## Last Night's Sleep", "- Sleep Score: #{score}/100"]
    lines << "- Deep Sleep: #{c['deep_sleep']}/100" if c["deep_sleep"]
    lines << "- REM Sleep: #{c['rem_sleep']}/100" if c["rem_sleep"]
    lines << "- Efficiency: #{c['efficiency']}/100" if c["efficiency"]
    lines.join("\n")
  end

  def format_readiness_context
    latest = health_data.dig("readiness")&.max_by { |d| d["day"] }
    return unless latest

    score = latest["score"]
    c = latest["contributors"] || {}

    lines = ["## Today's Readiness", "- Readiness Score: #{score}/100"]
    lines << "- HRV Balance: #{c['hrv_balance']}/100" if c["hrv_balance"]
    lines << "- Recovery: #{c['recovery_index']}/100" if c["recovery_index"]
    lines.join("\n")
  end

  def format_activity_context
    latest = health_data.dig("activity")&.max_by { |d| d["day"] }
    return unless latest

    lines = ["## Yesterday's Activity", "- Activity Score: #{latest['score']}/100"]
    lines << "- Steps: #{latest['steps'].to_i.to_fs(:delimited)}" if latest["steps"]
    lines << "- Active Calories: #{latest['active_calories'].to_i}" if latest["active_calories"]
    lines.join("\n")
  end
end
```

---

## Summary

The spec is 80% there. The problems are:

1. **Column naming** - fight with Rails conventions
2. **Scope creep** - granular sharing toggles, scopes tracking
3. **Misplaced concerns** - OAuth state in the model
4. **Context injection** - overly complex user lookup

Ship the simple version. Add complexity when users ask for it. The best code is code you didn't write.
