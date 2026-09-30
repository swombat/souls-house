# Oura Ring Integration

**Date**: 2026-01-27
**Version**: 01a
**Status**: Draft

## Executive Summary

This specification details the implementation of an Oura Ring integration that allows users to connect their Oura account via OAuth and automatically inject their health data (sleep, readiness, activity) into agent system prompts. This enables AI agents to be contextually aware of the user's physical state without requiring explicit queries.

The implementation follows Rails conventions: business logic in models, thin controllers, no service objects, and association-based authorization.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Settings UI                             │
│                    (Svelte: user/integrations.svelte)                │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    OuraIntegrationsController                        │
│              (OAuth flow, connect/disconnect actions)                │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        OuraIntegration Model                         │
│     (Token storage, API calls, health data formatting)               │
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

1. **Connection**: User clicks "Connect Oura Ring" -> OAuth redirect -> callback stores tokens
2. **Data Sync**: Background job fetches health data daily (after typical sync time ~9am user time)
3. **Context Injection**: `Chat#system_message_for(agent)` includes health context from `User#oura_health_context`

## Implementation Plan

### Phase 1: Database Schema

- [ ] **1.1 Create OuraIntegration migration**

  ```ruby
  # db/migrate/YYYYMMDDHHMMSS_create_oura_integrations.rb
  class CreateOuraIntegrations < ActiveRecord::Migration[8.1]
    def change
      create_table :oura_integrations do |t|
        t.references :user, null: false, foreign_key: true, index: { unique: true }

        # OAuth tokens (encrypted at rest via Rails 7+ encryption)
        t.text :access_token_ciphertext
        t.text :refresh_token_ciphertext
        t.datetime :token_expires_at

        # Granted scopes (stored as array)
        t.string :scopes, array: true, default: []

        # Cached health data (refreshed daily)
        t.jsonb :health_data, default: {}
        t.datetime :health_data_synced_at

        # User preferences
        t.boolean :enabled, default: true, null: false
        t.boolean :share_sleep, default: true, null: false
        t.boolean :share_readiness, default: true, null: false
        t.boolean :share_activity, default: true, null: false

        # OAuth state for CSRF protection
        t.string :oauth_state
        t.datetime :oauth_state_expires_at

        t.timestamps
      end
    end
  end
  ```

### Phase 2: OuraIntegration Model

- [ ] **2.1 Create OuraIntegration model with encrypted tokens**

  ```ruby
  # app/models/oura_integration.rb
  class OuraIntegration < ApplicationRecord

    OURA_AUTHORIZE_URL = "https://cloud.ouraring.com/oauth/authorize"
    OURA_TOKEN_URL = "https://api.ouraring.com/oauth/token"
    OURA_API_BASE = "https://api.ouraring.com/v2"

    REQUESTED_SCOPES = %w[email personal daily heartrate].freeze
    TOKEN_EXPIRY_BUFFER = 1.day

    belongs_to :user

    # Rails 7+ attribute encryption
    encrypts :access_token_ciphertext
    encrypts :refresh_token_ciphertext

    validates :user_id, uniqueness: true

    scope :enabled, -> { where(enabled: true) }
    scope :needs_sync, -> { enabled.where("health_data_synced_at IS NULL OR health_data_synced_at < ?", 6.hours.ago) }
    scope :with_valid_tokens, -> { where("token_expires_at > ?", Time.current) }

    # Generate OAuth authorization URL with CSRF state
    def authorization_url(redirect_uri:)
      self.oauth_state = SecureRandom.hex(32)
      self.oauth_state_expires_at = 10.minutes.from_now
      save!

      params = {
        response_type: "code",
        client_id: oura_client_id,
        redirect_uri: redirect_uri,
        scope: REQUESTED_SCOPES.join(" "),
        state: oauth_state
      }

      "#{OURA_AUTHORIZE_URL}?#{params.to_query}"
    end

    # Exchange authorization code for tokens
    def exchange_code!(code:, redirect_uri:)
      response = HTTParty.post(OURA_TOKEN_URL, body: {
        grant_type: "authorization_code",
        code: code,
        client_id: oura_client_id,
        client_secret: oura_client_secret,
        redirect_uri: redirect_uri
      })

      handle_token_response!(response)
    end

    # Refresh expired tokens
    def refresh_tokens!
      return if token_valid?

      response = HTTParty.post(OURA_TOKEN_URL, body: {
        grant_type: "refresh_token",
        refresh_token: refresh_token_ciphertext,
        client_id: oura_client_id,
        client_secret: oura_client_secret
      })

      handle_token_response!(response)
    end

    def token_valid?
      token_expires_at.present? && token_expires_at > TOKEN_EXPIRY_BUFFER.from_now
    end

    def connected?
      access_token_ciphertext.present? && token_expires_at.present?
    end

    # Sync health data from Oura API
    def sync_health_data!
      refresh_tokens! unless token_valid?
      return unless connected?

      today = Date.current
      yesterday = today - 1.day

      data = {
        sleep: fetch_daily_sleep(yesterday, today),
        readiness: fetch_daily_readiness(yesterday, today),
        activity: fetch_daily_activity(yesterday, today),
        synced_at: Time.current.iso8601
      }

      update!(health_data: data, health_data_synced_at: Time.current)
    end

    # Format health data for system prompt injection
    def health_context
      return nil unless enabled? && health_data.present?

      parts = []

      if share_sleep? && health_data["sleep"].present?
        parts << format_sleep_context(health_data["sleep"])
      end

      if share_readiness? && health_data["readiness"].present?
        parts << format_readiness_context(health_data["readiness"])
      end

      if share_activity? && health_data["activity"].present?
        parts << format_activity_context(health_data["activity"])
      end

      return nil if parts.empty?

      freshness = health_data_synced_at ? "(synced #{time_ago_in_words(health_data_synced_at)} ago)" : ""

      "# User Health Data from Oura Ring #{freshness}\n\n" + parts.join("\n\n")
    end

    # Disconnect and revoke tokens
    def disconnect!
      if access_token_ciphertext.present?
        HTTParty.get("https://api.ouraring.com/oauth/revoke?access_token=#{access_token_ciphertext}")
      rescue StandardError => e
        Rails.logger.warn("Failed to revoke Oura token: #{e.message}")
      end

      update!(
        access_token_ciphertext: nil,
        refresh_token_ciphertext: nil,
        token_expires_at: nil,
        scopes: [],
        health_data: {},
        health_data_synced_at: nil,
        oauth_state: nil,
        oauth_state_expires_at: nil
      )
    end

    private

    def oura_client_id
      Rails.application.credentials.dig(:oura, :client_id) ||
        raise(ArgumentError, "Oura client_id not configured in credentials")
    end

    def oura_client_secret
      Rails.application.credentials.dig(:oura, :client_secret) ||
        raise(ArgumentError, "Oura client_secret not configured in credentials")
    end

    def handle_token_response!(response)
      unless response.success?
        raise OuraApiError, "Token exchange failed: #{response.code} - #{response.body}"
      end

      result = JSON.parse(response.body)

      update!(
        access_token_ciphertext: result["access_token"],
        refresh_token_ciphertext: result["refresh_token"],
        token_expires_at: Time.current + result["expires_in"].to_i.seconds,
        oauth_state: nil,
        oauth_state_expires_at: nil
      )
    end

    def fetch_daily_sleep(start_date, end_date)
      fetch_endpoint("/usercollection/daily_sleep", start_date, end_date)
    end

    def fetch_daily_readiness(start_date, end_date)
      fetch_endpoint("/usercollection/daily_readiness", start_date, end_date)
    end

    def fetch_daily_activity(start_date, end_date)
      fetch_endpoint("/usercollection/daily_activity", start_date, end_date)
    end

    def fetch_endpoint(endpoint, start_date, end_date)
      response = HTTParty.get(
        "#{OURA_API_BASE}#{endpoint}",
        headers: { "Authorization" => "Bearer #{access_token_ciphertext}" },
        query: { start_date: start_date.to_s, end_date: end_date.to_s }
      )

      return nil unless response.success?

      JSON.parse(response.body)["data"]
    rescue StandardError => e
      Rails.logger.error("Oura API error for #{endpoint}: #{e.message}")
      nil
    end

    def format_sleep_context(sleep_data)
      latest = sleep_data.max_by { |d| d["day"] }
      return nil unless latest

      score = latest["score"]
      contributors = latest["contributors"] || {}

      lines = ["## Last Night's Sleep"]
      lines << "- **Sleep Score**: #{score}/100"
      lines << "- **Deep Sleep**: #{contributors['deep_sleep']}/100" if contributors["deep_sleep"]
      lines << "- **REM Sleep**: #{contributors['rem_sleep']}/100" if contributors["rem_sleep"]
      lines << "- **Sleep Efficiency**: #{contributors['efficiency']}/100" if contributors["efficiency"]
      lines << "- **Restfulness**: #{contributors['restfulness']}/100" if contributors["restfulness"]

      lines.join("\n")
    end

    def format_readiness_context(readiness_data)
      latest = readiness_data.max_by { |d| d["day"] }
      return nil unless latest

      score = latest["score"]
      contributors = latest["contributors"] || {}
      temp_deviation = latest["temperature_deviation"]

      lines = ["## Today's Readiness"]
      lines << "- **Readiness Score**: #{score}/100"
      lines << "- **HRV Balance**: #{contributors['hrv_balance']}/100" if contributors["hrv_balance"]
      lines << "- **Resting Heart Rate**: #{contributors['resting_heart_rate']}/100" if contributors["resting_heart_rate"]
      lines << "- **Recovery Index**: #{contributors['recovery_index']}/100" if contributors["recovery_index"]
      lines << "- **Temperature Deviation**: #{temp_deviation.round(1)}C" if temp_deviation

      lines.join("\n")
    end

    def format_activity_context(activity_data)
      latest = activity_data.max_by { |d| d["day"] }
      return nil unless latest

      score = latest["score"]
      steps = latest["steps"]
      calories = latest["active_calories"]

      lines = ["## Yesterday's Activity"]
      lines << "- **Activity Score**: #{score}/100"
      lines << "- **Steps**: #{steps.to_i.to_s(:delimited)}" if steps
      lines << "- **Active Calories**: #{calories.to_i}" if calories

      lines.join("\n")
    end

    def time_ago_in_words(time)
      ActionController::Base.helpers.time_ago_in_words(time)
    end
  end

  class OuraApiError < StandardError; end
  ```

- [ ] **2.2 Add OuraIntegration association to User model**

  ```ruby
  # In app/models/user.rb, add:
  has_one :oura_integration, dependent: :destroy

  # Delegate health context for easy access
  def oura_health_context
    oura_integration&.health_context
  end
  ```

### Phase 3: Context Injection

- [ ] **3.1 Modify Chat#system_message_for to include health data**

  In `/app/models/chat.rb`, update the `system_message_for` method to inject Oura health context. Add after the memory context section:

  ```ruby
  def system_message_for(agent)
    parts = []

    parts << (agent.system_prompt.presence || "You are #{agent.name}.")

    if (memory_context = agent.memory_context)
      parts << memory_context
    end

    # NEW: Add Oura health context
    if (health_context = user_health_context)
      parts << health_context
    end

    if (whiteboard_index = whiteboard_index_context)
      parts << whiteboard_index
    end

    # ... rest of existing code
  end

  private

  # NEW: Get health context from the most recent human participant
  def user_health_context
    # Find the most recent user who sent a message
    recent_user = messages.where.not(user_id: nil)
                          .order(created_at: :desc)
                          .limit(1)
                          .pick(:user_id)

    return nil unless recent_user

    User.find(recent_user).oura_health_context
  rescue ActiveRecord::RecordNotFound
    nil
  end
  ```

### Phase 4: Background Sync Job

- [ ] **4.1 Create SyncOuraDataJob**

  ```ruby
  # app/jobs/sync_oura_data_job.rb
  class SyncOuraDataJob < ApplicationJob
    queue_as :default

    # Retry with exponential backoff for API failures
    retry_on OuraApiError, wait: :polynomially_longer, attempts: 3

    def perform(oura_integration_id = nil)
      if oura_integration_id
        # Sync specific integration
        integration = OuraIntegration.find(oura_integration_id)
        sync_integration(integration)
      else
        # Sync all integrations that need updating
        OuraIntegration.needs_sync.with_valid_tokens.find_each do |integration|
          SyncOuraDataJob.perform_later(integration.id)
        end
      end
    end

    private

    def sync_integration(integration)
      integration.sync_health_data!
    rescue OuraApiError => e
      Rails.logger.error("Failed to sync Oura data for user #{integration.user_id}: #{e.message}")
      raise
    end
  end
  ```

- [ ] **4.2 Schedule daily sync in recurring jobs**

  Add to the recurring job schedule (if using solid_queue recurring):

  ```yaml
  # config/recurring.yml
  sync_oura_data:
    class: SyncOuraDataJob
    schedule: every 4 hours
  ```

  Or trigger via cron/whenever if preferred.

### Phase 5: Controller

- [ ] **5.1 Create OuraIntegrationsController**

  ```ruby
  # app/controllers/oura_integrations_controller.rb
  class OuraIntegrationsController < ApplicationController

    before_action :set_integration, only: [:update, :destroy]

    def show
      integration = Current.user.oura_integration || Current.user.build_oura_integration

      render inertia: "integrations/oura", props: {
        integration: integration_json(integration),
        connected: integration.connected?
      }
    end

    def create
      integration = Current.user.oura_integration || Current.user.create_oura_integration!
      redirect_url = integration.authorization_url(redirect_uri: callback_oura_integrations_url)

      redirect_to redirect_url, allow_other_host: true
    end

    def callback
      integration = Current.user.oura_integration

      if params[:error]
        redirect_to oura_integrations_path, alert: "Authorization was denied"
        return
      end

      unless integration&.oauth_state == params[:state] && integration.oauth_state_expires_at&.future?
        redirect_to oura_integrations_path, alert: "Invalid or expired authorization state"
        return
      end

      integration.exchange_code!(code: params[:code], redirect_uri: callback_oura_integrations_url)

      # Trigger initial data sync
      SyncOuraDataJob.perform_later(integration.id)

      redirect_to oura_integrations_path, notice: "Oura Ring connected successfully"
    rescue OuraApiError => e
      redirect_to oura_integrations_path, alert: "Failed to connect: #{e.message}"
    end

    def update
      @integration.update!(integration_params)
      redirect_to oura_integrations_path, notice: "Settings updated"
    end

    def destroy
      @integration.disconnect!
      redirect_to oura_integrations_path, notice: "Oura Ring disconnected"
    end

    def sync
      integration = Current.user.oura_integration

      if integration&.connected?
        SyncOuraDataJob.perform_later(integration.id)
        redirect_to oura_integrations_path, notice: "Sync started"
      else
        redirect_to oura_integrations_path, alert: "Not connected to Oura"
      end
    end

    private

    def set_integration
      @integration = Current.user.oura_integration
      redirect_to oura_integrations_path unless @integration
    end

    def integration_params
      params.require(:oura_integration).permit(:enabled, :share_sleep, :share_readiness, :share_activity)
    end

    def integration_json(integration)
      {
        id: integration.id,
        enabled: integration.enabled?,
        connected: integration.connected?,
        share_sleep: integration.share_sleep?,
        share_readiness: integration.share_readiness?,
        share_activity: integration.share_activity?,
        health_data_synced_at: integration.health_data_synced_at&.iso8601,
        token_expires_at: integration.token_expires_at&.iso8601
      }
    end
  end
  ```

### Phase 6: Routes

- [ ] **6.1 Add routes for Oura integration**

  ```ruby
  # config/routes.rb
  # Add within the authenticated section:

  resource :oura_integrations, only: [:show, :create, :update, :destroy] do
    get :callback, on: :collection
    post :sync, on: :member
  end
  ```

### Phase 7: Frontend UI

- [ ] **7.1 Create Oura integration settings page**

  ```svelte
  <!-- app/frontend/pages/integrations/oura.svelte -->
  <script>
    import { router } from '@inertiajs/svelte';
    import { Button } from '$lib/components/shadcn/button/index.js';
    import { Switch } from '$lib/components/shadcn/switch/index.js';
    import { Label } from '$lib/components/shadcn/label/index.js';
    import { Activity, Moon, Zap, Link, Unlink, RefreshCw } from 'phosphor-svelte';

    let { integration, connected } = $props();

    let settings = $state({ ...integration });
    let syncing = $state(false);

    function connect() {
      router.post('/oura_integrations');
    }

    function disconnect() {
      if (confirm('Disconnect your Oura Ring? Your health data will no longer be shared with agents.')) {
        router.delete('/oura_integrations');
      }
    }

    function updateSettings() {
      router.patch('/oura_integrations', { oura_integration: settings });
    }

    function syncNow() {
      syncing = true;
      router.post('/oura_integrations/sync', {}, {
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
              {#if connected}
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
          {#if connected}
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

    {#if connected}
      <div class="border rounded-lg p-6">
        <h2 class="font-semibold mb-4">Data Sharing Settings</h2>
        <p class="text-sm text-muted-foreground mb-6">
          Choose what health data to share with AI agents in your conversations.
        </p>

        <div class="space-y-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <Switch
                id="enabled"
                checked={settings.enabled}
                onCheckedChange={(checked) => {
                  settings.enabled = checked;
                  updateSettings();
                }}
              />
              <Label for="enabled" class="flex items-center gap-2">
                <Zap size={18} />
                Enable Health Data Sharing
              </Label>
            </div>
          </div>

          <div class="border-t pt-6 space-y-4 {settings.enabled ? '' : 'opacity-50 pointer-events-none'}">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <Switch
                  id="share_sleep"
                  checked={settings.share_sleep}
                  onCheckedChange={(checked) => {
                    settings.share_sleep = checked;
                    updateSettings();
                  }}
                />
                <Label for="share_sleep" class="flex items-center gap-2">
                  <Moon size={18} />
                  Share Sleep Data
                </Label>
              </div>
              <span class="text-sm text-muted-foreground">Sleep score, deep sleep, REM, etc.</span>
            </div>

            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <Switch
                  id="share_readiness"
                  checked={settings.share_readiness}
                  onCheckedChange={(checked) => {
                    settings.share_readiness = checked;
                    updateSettings();
                  }}
                />
                <Label for="share_readiness" class="flex items-center gap-2">
                  <Zap size={18} />
                  Share Readiness Data
                </Label>
              </div>
              <span class="text-sm text-muted-foreground">Readiness score, HRV, recovery index</span>
            </div>

            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <Switch
                  id="share_activity"
                  checked={settings.share_activity}
                  onCheckedChange={(checked) => {
                    settings.share_activity = checked;
                    updateSettings();
                  }}
                />
                <Label for="share_activity" class="flex items-center gap-2">
                  <Activity size={18} />
                  Share Activity Data
                </Label>
              </div>
              <span class="text-sm text-muted-foreground">Steps, active calories, activity score</span>
            </div>
          </div>
        </div>
      </div>

      <div class="mt-6 p-4 bg-muted/50 rounded-lg">
        <h3 class="font-medium mb-2">How it works</h3>
        <p class="text-sm text-muted-foreground">
          When enabled, your latest health data is automatically included in conversations with AI agents.
          This allows agents to be aware of your physical state and provide more contextual responses.
          For example, an agent might notice you had poor sleep and suggest taking it easy.
        </p>
      </div>
    {/if}
  </div>
  ```

- [ ] **7.2 Add link to integrations from user settings**

  Add to the user settings navigation or as a separate menu item:

  ```svelte
  <!-- In navigation or user settings page -->
  <a href="/oura_integrations" class="...">
    <Activity size={18} />
    Oura Ring Integration
  </a>
  ```

### Phase 8: Credentials Configuration

- [ ] **8.1 Document credentials setup**

  Add Oura credentials to Rails encrypted credentials:

  ```yaml
  # rails credentials:edit
  oura:
    client_id: "your_oura_client_id"
    client_secret: "your_oura_client_secret"
  ```

  Register the OAuth application at https://cloud.ouraring.com with:
  - Redirect URI: `https://yourdomain.com/oura_integrations/callback`
  - Requested scopes: `email personal daily heartrate`

### Phase 9: Testing Strategy

- [ ] **9.1 Model tests for OuraIntegration**

  ```ruby
  # test/models/oura_integration_test.rb
  class OuraIntegrationTest < ActiveSupport::TestCase
    setup do
      @user = users(:confirmed_user)
      @integration = OuraIntegration.create!(user: @user)
    end

    test "generates authorization URL with CSRF state" do
      url = @integration.authorization_url(redirect_uri: "http://test.com/callback")

      assert_includes url, "cloud.ouraring.com/oauth/authorize"
      assert_includes url, "state="
      assert @integration.oauth_state.present?
      assert @integration.oauth_state_expires_at > Time.current
    end

    test "validates uniqueness of user" do
      duplicate = OuraIntegration.new(user: @user)
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:user_id], "has already been taken"
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
        share_sleep: true,
        health_data: {
          "sleep" => [{ "day" => "2026-01-26", "score" => 85, "contributors" => { "deep_sleep" => 70 } }]
        },
        health_data_synced_at: 1.hour.ago
      )

      context = @integration.health_context
      assert_includes context, "Sleep Score"
      assert_includes context, "85/100"
    end

    test "disconnect clears all data" do
      @integration.update!(
        access_token_ciphertext: "token",
        refresh_token_ciphertext: "refresh",
        health_data: { "sleep" => [] }
      )

      @integration.disconnect!

      assert_nil @integration.access_token_ciphertext
      assert_nil @integration.refresh_token_ciphertext
      assert_equal({}, @integration.health_data)
    end
  end
  ```

- [ ] **9.2 Controller tests**

  ```ruby
  # test/controllers/oura_integrations_controller_test.rb
  class OuraIntegrationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:confirmed_user)
      sign_in(@user)
    end

    test "show renders integration page" do
      get oura_integrations_path
      assert_response :success
    end

    test "create redirects to Oura OAuth" do
      post oura_integrations_path
      assert_response :redirect
      assert_includes response.location, "cloud.ouraring.com/oauth/authorize"
    end

    test "callback with error redirects with alert" do
      @user.create_oura_integration!(oauth_state: "test", oauth_state_expires_at: 5.minutes.from_now)

      get callback_oura_integrations_path(error: "access_denied")

      assert_redirected_to oura_integrations_path
      assert_equal "Authorization was denied", flash[:alert]
    end

    test "callback with invalid state rejects" do
      @user.create_oura_integration!(oauth_state: "test", oauth_state_expires_at: 5.minutes.from_now)

      get callback_oura_integrations_path(code: "abc", state: "wrong")

      assert_redirected_to oura_integrations_path
      assert_includes flash[:alert], "Invalid"
    end

    test "destroy disconnects integration" do
      integration = @user.create_oura_integration!(
        access_token_ciphertext: "token",
        token_expires_at: 1.day.from_now
      )

      delete oura_integrations_path

      assert_redirected_to oura_integrations_path
      integration.reload
      assert_nil integration.access_token_ciphertext
    end

    test "update changes sharing settings" do
      integration = @user.create_oura_integration!

      patch oura_integrations_path, params: { oura_integration: { share_sleep: false } }

      assert_redirected_to oura_integrations_path
      assert_not integration.reload.share_sleep?
    end
  end
  ```

- [ ] **9.3 VCR cassettes for API calls**

  Use VCR to record Oura API interactions for reliable test playback.

### Phase 10: Error Handling and Edge Cases

- [ ] **10.1 Handle token expiration gracefully**

  The model already handles token refresh, but ensure the sync job handles failures:

  ```ruby
  # In SyncOuraDataJob, tokens are refreshed before API calls
  # If refresh fails, job retries with exponential backoff
  ```

- [ ] **10.2 Handle disconnected/revoked tokens**

  If Oura returns 401, mark integration as needing reconnection:

  ```ruby
  # In OuraIntegration#fetch_endpoint
  if response.code == 401
    update!(access_token_ciphertext: nil, token_expires_at: nil)
    return nil
  end
  ```

- [ ] **10.3 Rate limiting**

  Oura allows 5000 requests per 5 minutes. With daily syncs per user, this is unlikely to be hit, but add logging:

  ```ruby
  if response.code == 429
    Rails.logger.warn("Oura rate limit hit for user #{user_id}")
    raise OuraApiError, "Rate limit exceeded"
  end
  ```

## File Summary

| File | Purpose |
|------|---------|
| `db/migrate/YYYYMMDDHHMMSS_create_oura_integrations.rb` | Database schema |
| `app/models/oura_integration.rb` | Main model with OAuth, API, and formatting logic |
| `app/models/user.rb` | Add `has_one :oura_integration` |
| `app/models/chat.rb` | Inject health context in `system_message_for` |
| `app/controllers/oura_integrations_controller.rb` | OAuth flow and settings |
| `app/jobs/sync_oura_data_job.rb` | Background data sync |
| `app/frontend/pages/integrations/oura.svelte` | Settings UI |
| `config/routes.rb` | Add integration routes |
| `test/models/oura_integration_test.rb` | Model tests |
| `test/controllers/oura_integrations_controller_test.rb` | Controller tests |

## External Dependencies

**None required.** The implementation uses:
- `HTTParty` (already in Gemfile for HTTP requests)
- Rails 7+ built-in attribute encryption
- Standard Rails credentials

## Security Considerations

1. **Token encryption**: Access and refresh tokens are encrypted at rest using Rails attribute encryption
2. **CSRF protection**: OAuth state parameter prevents cross-site request forgery
3. **Scope limitation**: Only request necessary scopes (email, personal, daily, heartrate)
4. **Token revocation**: Disconnect properly revokes tokens with Oura
5. **User control**: Users can disable sharing or disconnect at any time

## Future Enhancements (Out of Scope)

1. **Webhook support**: Could receive real-time updates instead of polling
2. **Historical data**: Allow viewing trends over time in the UI
3. **Multiple wearables**: Abstract to support Whoop, Apple Watch, etc.
4. **Per-agent settings**: Allow enabling health data for specific agents only
