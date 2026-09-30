# Oura Ring Integration

**Date**: 2026-01-27
**Version**: 01c (Final - Implementation Ready)
**Status**: Approved

## Executive Summary

This specification details the implementation of an Oura Ring integration that allows users to connect their Oura account via OAuth and automatically inject their health data (sleep, readiness, activity) into agent system prompts. This enables AI agents to be contextually aware of the user's physical state without requiring explicit queries.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Settings UI                             │
│                    (Svelte: settings/oura_integration.svelte)        │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    OuraIntegrationController                         │
│              (OAuth flow, connect/disconnect actions)                │
│              (OAuth state stored in session)                         │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        OuraIntegration Model                         │
│                 (Token storage, health data formatting)              │
│                   includes OuraApi concern for HTTP                  │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
         ┌──────────────────┐            ┌──────────────────┐
         │  SyncOuraDataJob │            │   Chat Model     │
         │  (Background)    │            │  (Context Inject)│
         └──────────────────┘            └──────────────────┘
```

### Data Flow

1. **Connection**: User clicks "Connect Oura Ring" -> OAuth state stored in session -> redirect to Oura -> callback validates session state -> tokens stored
2. **Data Sync**: Background job fetches health data every 4 hours for enabled integrations
3. **Context Injection**: `Chat#system_message_for(agent)` includes health context via `account.owner&.oura_health_context`

---

## Implementation Plan

### Phase 1: Database Schema

- [ ] **1.1 Create OuraIntegration migration**

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_oura_integrations.rb
class CreateOuraIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :oura_integrations do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }

      # OAuth tokens (encrypted via Rails attribute encryption)
      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at

      # Cached health data (refreshed periodically)
      t.jsonb :health_data, default: {}
      t.datetime :health_data_synced_at

      # User preference - single toggle
      t.boolean :enabled, default: true, null: false

      t.timestamps
    end
  end
end
```

**Run migration:**
```bash
rails generate migration CreateOuraIntegrations
# Edit the migration file with the above content
rails db:migrate
```

---

### Phase 2: OuraIntegration Model with Extracted Concern

- [ ] **2.1 Create OuraApi concern for HTTP operations**

```ruby
# app/models/concerns/oura_api.rb
module OuraApi
  extend ActiveSupport::Concern

  OURA_AUTHORIZE_URL = "https://cloud.ouraring.com/oauth/authorize"
  OURA_TOKEN_URL = "https://api.ouraring.com/oauth/token"
  OURA_API_BASE = "https://api.ouraring.com/v2"
  SCOPES = %w[email personal daily heartrate].freeze

  class Error < StandardError; end

  included do
    encrypts :access_token
    encrypts :refresh_token
  end

  def authorization_url(state:, redirect_uri:)
    params = {
      response_type: "code",
      client_id: oura_credentials(:client_id),
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
      client_id: oura_credentials(:client_id),
      client_secret: oura_credentials(:client_secret),
      redirect_uri: redirect_uri
    })

    save_tokens!(response)
  end

  def refresh_tokens!
    return if token_fresh?

    response = HTTParty.post(OURA_TOKEN_URL, body: {
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: oura_credentials(:client_id),
      client_secret: oura_credentials(:client_secret)
    })

    save_tokens!(response)
  end

  def token_fresh?
    token_expires_at.present? && token_expires_at > 1.day.from_now
  end

  def connected?
    access_token.present? && token_expires_at&.future?
  end

  def fetch_health_data
    today = Date.current
    yesterday = today - 1.day

    {
      "sleep" => fetch_endpoint("/usercollection/daily_sleep", yesterday, today),
      "readiness" => fetch_endpoint("/usercollection/daily_readiness", yesterday, today),
      "activity" => fetch_endpoint("/usercollection/daily_activity", yesterday, today)
    }
  end

  def revoke_token
    return unless access_token.present?
    HTTParty.get("https://api.ouraring.com/oauth/revoke", query: { access_token: access_token })
  rescue StandardError
    # Token revocation is best-effort, don't fail disconnect
  end

  private

  def oura_credentials(key)
    Rails.application.credentials.dig(:oura, key) ||
      raise(ArgumentError, "Oura #{key} not configured in credentials")
  end

  def save_tokens!(response)
    raise Error, "Token exchange failed: #{response.code}" unless response.success?

    data = JSON.parse(response.body)
    update!(
      access_token: data["access_token"],
      refresh_token: data["refresh_token"],
      token_expires_at: data["expires_in"].to_i.seconds.from_now
    )
  end

  def fetch_endpoint(path, start_date, end_date)
    response = HTTParty.get(
      "#{OURA_API_BASE}#{path}",
      headers: { "Authorization" => "Bearer #{access_token}" },
      query: { start_date: start_date.to_s, end_date: end_date.to_s }
    )

    if response.code == 401
      update!(access_token: nil, token_expires_at: nil)
      return nil
    end

    if response.code == 429
      Rails.logger.warn("Oura rate limit hit for user #{user_id}")
      return nil
    end

    return nil unless response.success?
    JSON.parse(response.body)["data"]
  rescue StandardError => e
    Rails.logger.error("Oura API error for #{path}: #{e.message}")
    nil
  end
end
```

- [ ] **2.2 Create OuraIntegration model**

```ruby
# app/models/oura_integration.rb
class OuraIntegration < ApplicationRecord
  include OuraApi

  belongs_to :user

  validates :user_id, uniqueness: true

  scope :enabled, -> { where(enabled: true) }
  scope :needs_sync, -> { enabled.where("health_data_synced_at IS NULL OR health_data_synced_at < ?", 6.hours.ago) }
  scope :with_valid_tokens, -> { where("token_expires_at > ?", Time.current) }

  def sync_health_data!
    refresh_tokens! unless token_fresh?
    return unless connected?

    update!(
      health_data: fetch_health_data,
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
    revoke_token
    update!(
      access_token: nil,
      refresh_token: nil,
      token_expires_at: nil,
      health_data: {},
      health_data_synced_at: nil
    )
  end

  private

  def format_sleep_context
    latest = health_data.dig("sleep")&.max_by { |d| d["day"] }
    return unless latest

    score = latest["score"]
    c = latest["contributors"] || {}

    lines = ["## Last Night's Sleep", "- Sleep Score: #{score}/100"]
    lines << "- Deep Sleep: #{c['deep_sleep']}/100" if c["deep_sleep"]
    lines << "- REM Sleep: #{c['rem_sleep']}/100" if c["rem_sleep"]
    lines << "- Efficiency: #{c['efficiency']}/100" if c["efficiency"]
    lines << "- Restfulness: #{c['restfulness']}/100" if c["restfulness"]
    lines.join("\n")
  end

  def format_readiness_context
    latest = health_data.dig("readiness")&.max_by { |d| d["day"] }
    return unless latest

    score = latest["score"]
    c = latest["contributors"] || {}

    lines = ["## Today's Readiness", "- Readiness Score: #{score}/100"]
    lines << "- HRV Balance: #{c['hrv_balance']}/100" if c["hrv_balance"]
    lines << "- Recovery Index: #{c['recovery_index']}/100" if c["recovery_index"]
    lines << "- Resting Heart Rate: #{c['resting_heart_rate']}/100" if c["resting_heart_rate"]

    if latest["temperature_deviation"]
      lines << "- Temperature Deviation: #{latest['temperature_deviation'].round(1)}C"
    end

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

- [ ] **2.3 Add OuraIntegration association to User model**

In `app/models/user.rb`, add:

```ruby
has_one :oura_integration, dependent: :destroy

def oura_health_context
  oura_integration&.health_context
end
```

---

### Phase 3: Context Injection

- [ ] **3.1 Modify Chat#system_message_for to include health data**

In `/app/models/chat.rb`, locate the `system_message_for` method and add health context injection:

```ruby
def system_message_for(agent)
  parts = []

  parts << (agent.system_prompt.presence || "You are #{agent.name}.")

  if (memory_context = agent.memory_context)
    parts << memory_context
  end

  # Health context from account owner's Oura integration
  if (health_context = account.owner&.oura_health_context)
    parts << health_context
  end

  if (whiteboard_index = whiteboard_index_context)
    parts << whiteboard_index
  end

  # ... rest of existing code unchanged
end
```

---

### Phase 4: Background Sync Job

- [ ] **4.1 Create SyncOuraDataJob**

```ruby
# app/jobs/sync_oura_data_job.rb
class SyncOuraDataJob < ApplicationJob
  queue_as :default

  retry_on OuraApi::Error, wait: :polynomially_longer, attempts: 3

  def perform(oura_integration_id = nil)
    if oura_integration_id
      sync_one(oura_integration_id)
    else
      sync_all
    end
  end

  private

  def sync_one(id)
    OuraIntegration.find(id).sync_health_data!
  rescue OuraApi::Error => e
    Rails.logger.error("Oura sync failed for integration #{id}: #{e.message}")
    raise
  end

  def sync_all
    OuraIntegration.needs_sync.with_valid_tokens.find_each do |integration|
      SyncOuraDataJob.perform_later(integration.id)
    end
  end
end
```

- [ ] **4.2 Schedule recurring sync**

```yaml
# config/recurring.yml
sync_oura_data:
  class: SyncOuraDataJob
  schedule: every 4 hours
```

---

### Phase 5: Controller

- [ ] **5.1 Create OuraIntegrationController (singular resource)**

```ruby
# app/controllers/oura_integration_controller.rb
class OuraIntegrationController < ApplicationController
  def show
    integration = Current.user.oura_integration || Current.user.build_oura_integration

    render inertia: "settings/oura_integration", props: {
      integration: integration_json(integration)
    }
  end

  def create
    state = SecureRandom.hex(32)
    session[:oura_oauth_state] = state
    session[:oura_oauth_state_expires_at] = 10.minutes.from_now.to_i

    integration = Current.user.oura_integration || Current.user.create_oura_integration!
    redirect_to integration.authorization_url(state: state, redirect_uri: callback_oura_integration_url),
                allow_other_host: true
  end

  def callback
    if params[:error]
      redirect_to oura_integration_path, alert: "Authorization was denied"
      return
    end

    expected_state = session.delete(:oura_oauth_state)
    expires_at = session.delete(:oura_oauth_state_expires_at)

    unless expected_state == params[:state] && Time.current.to_i < expires_at.to_i
      redirect_to oura_integration_path, alert: "Invalid or expired authorization"
      return
    end

    integration = Current.user.oura_integration
    integration.exchange_code!(code: params[:code], redirect_uri: callback_oura_integration_url)

    SyncOuraDataJob.perform_later(integration.id)

    redirect_to oura_integration_path, notice: "Oura Ring connected successfully"
  rescue OuraApi::Error => e
    redirect_to oura_integration_path, alert: "Failed to connect: #{e.message}"
  end

  def update
    integration = Current.user.oura_integration
    redirect_to oura_integration_path and return unless integration

    integration.update!(integration_params)
    redirect_to oura_integration_path, notice: "Settings updated"
  end

  def destroy
    integration = Current.user.oura_integration
    integration&.disconnect!

    redirect_to oura_integration_path, notice: "Oura Ring disconnected"
  end

  def sync
    integration = Current.user.oura_integration

    if integration&.connected?
      SyncOuraDataJob.perform_later(integration.id)
      redirect_to oura_integration_path, notice: "Sync started"
    else
      redirect_to oura_integration_path, alert: "Not connected to Oura"
    end
  end

  private

  def integration_params
    params.require(:oura_integration).permit(:enabled)
  end

  def integration_json(integration)
    {
      id: integration.id,
      enabled: integration.enabled?,
      connected: integration.connected?,
      health_data_synced_at: integration.health_data_synced_at&.iso8601,
      token_expires_at: integration.token_expires_at&.iso8601
    }
  end
end
```

---

### Phase 6: Routes

- [ ] **6.1 Add singular resource route**

In `config/routes.rb`, add within the authenticated section:

```ruby
resource :oura_integration, only: [:show, :create, :update, :destroy] do
  get :callback, on: :collection
  post :sync, on: :member
end
```

**Generated routes:**

| HTTP Method | Path | Controller#Action | Named Helper |
|-------------|------|-------------------|--------------|
| GET | /oura_integration | oura_integration#show | `oura_integration_path` |
| POST | /oura_integration | oura_integration#create | `oura_integration_path` |
| PATCH/PUT | /oura_integration | oura_integration#update | `oura_integration_path` |
| DELETE | /oura_integration | oura_integration#destroy | `oura_integration_path` |
| GET | /oura_integration/callback | oura_integration#callback | `callback_oura_integration_path` |
| POST | /oura_integration/sync | oura_integration#sync | `sync_oura_integration_path` |

---

### Phase 7: Frontend UI

- [ ] **7.1 Create Oura integration settings page**

```svelte
<!-- app/frontend/pages/settings/oura_integration.svelte -->
<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Switch } from '$lib/components/ui/switch/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { Activity, Link, Unlink, RefreshCw } from 'phosphor-svelte';

  let { integration } = $props();

  let syncing = $state(false);

  function connect() {
    router.post('/oura_integration');
  }

  function disconnect() {
    if (confirm('Disconnect your Oura Ring? Your health data will no longer be shared with agents.')) {
      router.delete('/oura_integration');
    }
  }

  function toggleEnabled(checked) {
    router.patch('/oura_integration', { oura_integration: { enabled: checked } });
  }

  function syncNow() {
    syncing = true;
    router.post('/oura_integration/sync', {}, {
      onFinish: () => { syncing = false; }
    });
  }

  function formatSyncTime(isoString) {
    if (!isoString) return 'Never';
    const date = new Date(isoString);
    return date.toLocaleString();
  }
</script>

<div class="container mx-auto p-8 max-w-4xl">
  <div class="mb-8">
    <h1 class="text-3xl font-bold mb-2">Oura Ring Integration</h1>
    <p class="text-muted-foreground">
      Connect your Oura Ring to share sleep, readiness, and activity data with AI agents.
    </p>
  </div>

  <div class="border rounded-lg p-6 mb-6">
    <div class="flex items-center justify-between mb-4">
      <div class="flex items-center gap-3">
        <div class="w-12 h-12 rounded-full bg-primary/10 flex items-center justify-center">
          <Activity size={24} class="text-primary" />
        </div>
        <div>
          <h2 class="font-semibold">Connection Status</h2>
          <p class="text-sm text-muted-foreground">
            {#if integration.connected}
              <span class="text-green-600">Connected</span>
              {#if integration.health_data_synced_at}
                - Last synced {formatSyncTime(integration.health_data_synced_at)}
              {/if}
            {:else}
              <span class="text-muted-foreground">Not connected</span>
            {/if}
          </p>
        </div>
      </div>

      <div class="flex gap-2">
        {#if integration.connected}
          <Button variant="outline" onclick={syncNow} disabled={syncing}>
            <RefreshCw size={16} class="mr-2" class:animate-spin={syncing} />
            Sync Now
          </Button>
          <Button variant="destructive" onclick={disconnect}>
            <Unlink size={16} class="mr-2" />
            Disconnect
          </Button>
        {:else}
          <Button onclick={connect}>
            <Link size={16} class="mr-2" />
            Connect Oura Ring
          </Button>
        {/if}
      </div>
    </div>
  </div>

  {#if integration.connected}
    <div class="border rounded-lg p-6">
      <h2 class="font-semibold mb-4">Settings</h2>

      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <Switch
            id="enabled"
            checked={integration.enabled}
            onCheckedChange={toggleEnabled}
          />
          <Label for="enabled">
            Share health data with AI agents
          </Label>
        </div>
      </div>

      <p class="text-sm text-muted-foreground mt-4">
        When enabled, your latest sleep, readiness, and activity data is included in
        conversations. This helps agents understand your physical state and provide
        more contextual responses.
      </p>
    </div>
  {/if}
</div>
```

- [ ] **7.2 Add link from user settings navigation**

Add to the user settings page or navigation menu:

```svelte
<a href="/oura_integration" class="...">
  <Activity size={18} />
  Oura Ring
</a>
```

---

### Phase 8: Credentials Configuration

- [ ] **8.1 Add Oura credentials to Rails credentials**

```bash
rails credentials:edit
```

Add:

```yaml
oura:
  client_id: "your_oura_client_id"
  client_secret: "your_oura_client_secret"
```

- [ ] **8.2 Register OAuth application at Oura**

1. Go to https://cloud.ouraring.com
2. Create a new application
3. Set redirect URI: `https://yourdomain.com/oura_integration/callback`
4. Requested scopes: `email personal daily heartrate`
5. Copy client ID and secret to Rails credentials

---

### Phase 9: Testing

- [ ] **9.1 Model tests**

```ruby
# test/models/oura_integration_test.rb
class OuraIntegrationTest < ActiveSupport::TestCase
  setup do
    @user = users(:confirmed_user)
    @integration = OuraIntegration.create!(user: @user)
  end

  test "generates authorization URL with provided state" do
    url = @integration.authorization_url(state: "test-state", redirect_uri: "http://test.com/callback")

    assert_includes url, "cloud.ouraring.com/oauth/authorize"
    assert_includes url, "state=test-state"
    assert_includes url, "redirect_uri=http%3A%2F%2Ftest.com%2Fcallback"
  end

  test "validates uniqueness of user" do
    duplicate = OuraIntegration.new(user: @user)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "connected? returns true with valid token" do
    @integration.update!(access_token: "token", token_expires_at: 1.day.from_now)
    assert @integration.connected?
  end

  test "connected? returns false with expired token" do
    @integration.update!(access_token: "token", token_expires_at: 1.day.ago)
    assert_not @integration.connected?
  end

  test "health_context returns nil when disabled" do
    @integration.update!(enabled: false, health_data: { "sleep" => [{ "score" => 85 }] })
    assert_nil @integration.health_context
  end

  test "health_context returns nil when no data" do
    @integration.update!(enabled: true, health_data: {})
    assert_nil @integration.health_context
  end

  test "health_context formats sleep data" do
    @integration.update!(
      enabled: true,
      health_data: {
        "sleep" => [{ "day" => "2026-01-26", "score" => 85, "contributors" => { "deep_sleep" => 70 } }]
      }
    )

    context = @integration.health_context
    assert_includes context, "Sleep Score: 85/100"
    assert_includes context, "Deep Sleep: 70/100"
  end

  test "disconnect clears all data" do
    @integration.update!(
      access_token: "token",
      refresh_token: "refresh",
      token_expires_at: 1.day.from_now,
      health_data: { "sleep" => [] }
    )

    @integration.disconnect!

    assert_nil @integration.access_token
    assert_nil @integration.refresh_token
    assert_nil @integration.token_expires_at
    assert_equal({}, @integration.health_data)
  end
end
```

- [ ] **9.2 Controller tests**

```ruby
# test/controllers/oura_integration_controller_test.rb
class OuraIntegrationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:confirmed_user)
    sign_in(@user)
  end

  test "show renders integration page" do
    get oura_integration_path
    assert_response :success
  end

  test "create stores state in session and redirects to Oura" do
    post oura_integration_path

    assert_response :redirect
    assert_includes response.location, "cloud.ouraring.com/oauth/authorize"
    assert session[:oura_oauth_state].present?
    assert session[:oura_oauth_state_expires_at].present?
  end

  test "callback with error redirects with alert" do
    @user.create_oura_integration!

    get callback_oura_integration_path(error: "access_denied")

    assert_redirected_to oura_integration_path
    assert_equal "Authorization was denied", flash[:alert]
  end

  test "callback with invalid state rejects" do
    @user.create_oura_integration!
    session[:oura_oauth_state] = "correct-state"
    session[:oura_oauth_state_expires_at] = 5.minutes.from_now.to_i

    get callback_oura_integration_path(code: "abc", state: "wrong-state")

    assert_redirected_to oura_integration_path
    assert_includes flash[:alert], "Invalid"
  end

  test "callback with expired state rejects" do
    @user.create_oura_integration!
    session[:oura_oauth_state] = "correct-state"
    session[:oura_oauth_state_expires_at] = 5.minutes.ago.to_i

    get callback_oura_integration_path(code: "abc", state: "correct-state")

    assert_redirected_to oura_integration_path
    assert_includes flash[:alert], "Invalid"
  end

  test "destroy disconnects integration" do
    integration = @user.create_oura_integration!(
      access_token: "token",
      token_expires_at: 1.day.from_now
    )

    delete oura_integration_path

    assert_redirected_to oura_integration_path
    integration.reload
    assert_nil integration.access_token
  end

  test "update changes enabled setting" do
    integration = @user.create_oura_integration!(enabled: true)

    patch oura_integration_path, params: { oura_integration: { enabled: false } }

    assert_redirected_to oura_integration_path
    assert_not integration.reload.enabled?
  end
end
```

- [ ] **9.3 VCR cassettes for API calls**

Use VCR to record Oura API interactions for reliable test playback.

---

## File Summary

| File | Purpose |
|------|---------|
| `db/migrate/YYYYMMDDHHMMSS_create_oura_integrations.rb` | Database schema |
| `app/models/concerns/oura_api.rb` | HTTP/OAuth operations concern |
| `app/models/oura_integration.rb` | Main model with health data formatting |
| `app/models/user.rb` | Add `has_one :oura_integration` and helper method |
| `app/models/chat.rb` | Inject health context in `system_message_for` |
| `app/controllers/oura_integration_controller.rb` | OAuth flow and settings |
| `app/jobs/sync_oura_data_job.rb` | Background data sync |
| `app/frontend/pages/settings/oura_integration.svelte` | Settings UI |
| `config/routes.rb` | Add singular resource route |
| `config/recurring.yml` | Schedule recurring sync job |
| `test/models/oura_integration_test.rb` | Model tests |
| `test/controllers/oura_integration_controller_test.rb` | Controller tests |

---

## External Dependencies

**None required.** The implementation uses:
- `HTTParty` (already in Gemfile for HTTP requests)
- Rails 7+ built-in attribute encryption
- Standard Rails credentials

---

## Security Considerations

1. **Token encryption**: Access and refresh tokens encrypted at rest via Rails attribute encryption
2. **CSRF protection**: OAuth state stored in session with 10-minute expiration
3. **Scope limitation**: Only request necessary scopes (email, personal, daily, heartrate)
4. **Token revocation**: Disconnect properly revokes tokens with Oura
5. **User control**: Users can disable sharing or disconnect at any time

---

## Implementation Checklist

### Phase 1: Database
- [ ] Create and run migration

### Phase 2: Models
- [ ] Create `app/models/concerns/oura_api.rb`
- [ ] Create `app/models/oura_integration.rb`
- [ ] Add association and helper to `app/models/user.rb`

### Phase 3: Context Injection
- [ ] Modify `Chat#system_message_for` in `app/models/chat.rb`

### Phase 4: Background Job
- [ ] Create `app/jobs/sync_oura_data_job.rb`
- [ ] Add schedule to `config/recurring.yml`

### Phase 5: Controller
- [ ] Create `app/controllers/oura_integration_controller.rb`

### Phase 6: Routes
- [ ] Add routes to `config/routes.rb`

### Phase 7: Frontend
- [ ] Create `app/frontend/pages/settings/oura_integration.svelte`
- [ ] Add navigation link to settings

### Phase 8: Configuration
- [ ] Add Oura credentials to Rails credentials
- [ ] Register OAuth app at cloud.ouraring.com

### Phase 9: Testing
- [ ] Create model tests
- [ ] Create controller tests
- [ ] Record VCR cassettes for API calls

### Final Verification
- [ ] Manual test: Connect Oura Ring
- [ ] Manual test: Verify health data appears in agent conversations
- [ ] Manual test: Disconnect and verify data is cleared
- [ ] Manual test: Toggle enabled setting

---

## Future Enhancements (Out of Scope for MVP)

1. **Webhook support**: Receive real-time updates instead of polling
2. **Historical data**: Allow viewing trends over time in the UI
3. **Multiple wearables**: Abstract to support Whoop, Apple Watch, etc.
4. **Per-agent settings**: Allow enabling health data for specific agents only
5. **Granular sharing**: Add back per-data-type toggles if users request it
