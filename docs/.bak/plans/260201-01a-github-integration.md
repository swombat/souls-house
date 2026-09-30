# GitHub Repository Integration

## Executive Summary

Add a GitHub repository integration that allows any member of a group account to link one GitHub repo via OAuth. Agents receive the last 10 commits as context during conversations and self-initiation decisions. Follows the existing Oura integration pattern closely, with key differences: belongs to Account (not User), no token refresh needed, and includes a repo selection step after OAuth.

## Architecture Overview

```
GithubIntegration (model)
  belongs_to :account
  includes GithubApi concern
  encrypts :access_token
  stores :recent_commits (JSONB), :repository_full_name

GithubIntegrationController (singular resource)
  show    -> settings page
  create  -> redirect to GitHub OAuth
  callback -> exchange code, redirect to repo selection
  select_repo -> save chosen repo, trigger sync
  update  -> toggle enabled
  destroy -> disconnect
  sync    -> manual refresh

SyncGithubCommitsJob
  fetches last 10 commits, stores in recent_commits JSONB

Context injection:
  Chat#system_message_for  -> injects commit context
  Agent#build_initiation_prompt -> injects commit context
```

## Implementation Plan

### 1. Migration

- [ ] Create `github_integrations` table

```ruby
class CreateGithubIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_integrations do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.text :access_token
      t.string :github_username
      t.string :repository_full_name
      t.jsonb :recent_commits, default: []
      t.datetime :commits_synced_at
      t.boolean :enabled, default: true, null: false
      t.timestamps
    end
  end
end
```

No `refresh_token` or `token_expires_at` -- GitHub OAuth tokens do not expire.

### 2. Model: `GithubIntegration`

- [ ] Create `app/models/github_integration.rb`
- [ ] Create `app/models/concerns/github_api.rb`

```ruby
# app/models/github_integration.rb
class GithubIntegration < ApplicationRecord
  include GithubApi

  belongs_to :account

  validates :account_id, uniqueness: true

  scope :enabled, -> { where(enabled: true) }
  scope :needs_sync, -> { enabled.where.not(repository_full_name: nil).where("commits_synced_at IS NULL OR commits_synced_at < ?", 1.hour.ago) }

  def sync_commits!
    return unless connected? && repository_full_name.present?

    update!(
      recent_commits: fetch_recent_commits,
      commits_synced_at: Time.current
    )
  end

  def commits_context
    return unless enabled? && recent_commits.present?

    lines = recent_commits.map do |c|
      "- #{c['sha']} #{c['date']}: #{c['message']} (#{c['author']})"
    end

    "# Recent Commits to #{repository_full_name}\n\n#{lines.join("\n")}"
  end

  def disconnect!
    update!(
      access_token: nil,
      github_username: nil,
      repository_full_name: nil,
      recent_commits: [],
      commits_synced_at: nil
    )
  end
end
```

```ruby
# app/models/concerns/github_api.rb
require "net/http"
require "json"

module GithubApi
  extend ActiveSupport::Concern

  GITHUB_AUTHORIZE_URL = "https://github.com/login/oauth/authorize"
  GITHUB_TOKEN_URL = "https://github.com/login/oauth/access_token"
  GITHUB_API_BASE = "https://api.github.com"
  API_VERSION = "2022-11-28"

  class Error < StandardError; end

  included do
    encrypts :access_token
  end

  def authorization_url(state:, redirect_uri:)
    params = {
      client_id: github_credentials(:client_id),
      redirect_uri: redirect_uri,
      scope: "repo",
      state: state,
      allow_signup: false
    }
    "#{GITHUB_AUTHORIZE_URL}?#{params.to_query}"
  end

  def exchange_code!(code:, redirect_uri:)
    uri = URI(GITHUB_TOKEN_URL)
    response = Net::HTTP.post_form(uri, {
      client_id: github_credentials(:client_id),
      client_secret: github_credentials(:client_secret),
      code: code,
      redirect_uri: redirect_uri
    })

    raise Error, "Token exchange failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    # GitHub returns URL-encoded by default; request JSON via Accept header
    # But post_form doesn't set Accept, so parse accordingly
    data = parse_token_response(response.body)
    raise Error, "No access token returned" unless data["access_token"]

    user_info = fetch_user(data["access_token"])

    update!(
      access_token: data["access_token"],
      github_username: user_info["login"]
    )
  end

  def connected?
    access_token.present?
  end

  def fetch_repos
    get("/user/repos", { visibility: "all", sort: "updated", direction: "desc", per_page: 100 })
  end

  def fetch_recent_commits(limit: 10)
    return [] unless repository_full_name.present?

    commits = get("/repos/#{repository_full_name}/commits", { per_page: limit })
    return [] unless commits.is_a?(Array)

    commits.map do |c|
      {
        "sha" => c["sha"]&.slice(0, 8),
        "message" => c.dig("commit", "message")&.lines&.first&.strip,
        "author" => c.dig("commit", "author", "name"),
        "date" => c.dig("commit", "author", "date")
      }
    end
  end

  private

  def github_credentials(key)
    Rails.application.credentials.dig(:github, key) ||
      raise(ArgumentError, "GitHub #{key} not configured in credentials")
  end

  def fetch_user(token)
    uri = URI("#{GITHUB_API_BASE}/user")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = API_VERSION

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    raise Error, "Failed to fetch user info" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def get(path, params = {})
    uri = URI("#{GITHUB_API_BASE}#{path}")
    uri.query = URI.encode_www_form(params) if params.any?

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = API_VERSION

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }

    if response.code == "401"
      update!(access_token: nil, github_username: nil)
      raise Error, "GitHub token revoked or invalid"
    end

    if response.code == "403" && response["X-RateLimit-Remaining"] == "0"
      Rails.logger.warn("GitHub rate limit hit for account #{account_id}")
      return nil
    end

    return nil unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error("GitHub API JSON parse error: #{e.message}")
    nil
  end

  def parse_token_response(body)
    JSON.parse(body)
  rescue JSON::ParserError
    URI.decode_www_form(body).to_h
  end
end
```

### 3. Account Model Association

- [ ] Add `has_one :github_integration` to `Account`
- [ ] Add `github_commits_context` convenience method

```ruby
# In app/models/account.rb
has_one :github_integration

def github_commits_context
  github_integration&.commits_context
end
```

### 4. Controller: `GithubIntegrationController`

- [ ] Create `app/controllers/github_integration_controller.rb`

The controller scopes through `current_account` (the user's current account context). Any account member can manage the integration since the route is within the account scope.

```ruby
class GithubIntegrationController < ApplicationController
  before_action :set_account
  before_action :set_integration, except: %i[show create]

  def show
    integration = @account.github_integration || @account.build_github_integration

    render inertia: "settings/github_integration", props: {
      integration: integration_json(integration)
    }
  end

  def create
    state = SecureRandom.hex(32)
    session[:github_oauth_state] = state
    session[:github_oauth_state_expires_at] = 10.minutes.from_now.to_i
    session[:github_oauth_account_id] = @account.id

    integration = @account.github_integration || @account.create_github_integration!

    redirect_to integration.authorization_url(state: state, redirect_uri: github_redirect_uri),
                allow_other_host: true
  end

  def callback
    if params[:error]
      redirect_to github_integration_path, alert: "Authorization was denied"
      return
    end

    expected_state = session.delete(:github_oauth_state)
    expires_at = session.delete(:github_oauth_state_expires_at)

    unless expected_state == params[:state] && Time.current.to_i < expires_at.to_i
      redirect_to github_integration_path, alert: "Invalid or expired authorization"
      return
    end

    unless @integration
      redirect_to github_integration_path, alert: "No integration found"
      return
    end

    @integration.exchange_code!(code: params[:code], redirect_uri: github_redirect_uri)

    redirect_to select_repo_github_integration_path
  rescue GithubApi::Error => e
    redirect_to github_integration_path, alert: "Failed to connect: #{e.message}"
  end

  def select_repo
    unless @integration&.connected?
      redirect_to github_integration_path, alert: "Not connected to GitHub"
      return
    end

    repos = @integration.fetch_repos
    repos_list = (repos || []).map { |r| { full_name: r["full_name"], private: r["private"] } }

    render inertia: "settings/github_select_repo", props: {
      repos: repos_list,
      current_repo: @integration.repository_full_name
    }
  end

  def save_repo
    unless @integration&.connected?
      redirect_to github_integration_path, alert: "Not connected to GitHub"
      return
    end

    @integration.update!(repository_full_name: params[:repository_full_name])
    SyncGithubCommitsJob.perform_later(@integration.id)

    redirect_to github_integration_path, notice: "Repository linked successfully"
  end

  def update
    redirect_to github_integration_path and return unless @integration

    @integration.update!(integration_params)
    redirect_to github_integration_path, notice: "Settings updated"
  end

  def destroy
    @integration&.disconnect!
    redirect_to github_integration_path, notice: "GitHub disconnected"
  end

  def sync
    if @integration&.connected? && @integration.repository_full_name.present?
      SyncGithubCommitsJob.perform_later(@integration.id)
      redirect_to github_integration_path, notice: "Sync started"
    else
      redirect_to github_integration_path, alert: "No repository linked"
    end
  end

  private

  def set_account
    @account = Current.user.accounts.find(session[:current_account_id] || Current.user.accounts.first.id)
  end

  def set_integration
    @integration = @account.github_integration
  end

  def github_redirect_uri
    base = Rails.application.credentials.dig(:app, :url) || request.base_url
    "#{base}/github_integration/callback"
  end

  def integration_params
    params.require(:github_integration).permit(:enabled)
  end

  def integration_json(integration)
    {
      id: integration.id,
      enabled: integration.enabled?,
      connected: integration.connected?,
      github_username: integration.github_username,
      repository_full_name: integration.repository_full_name,
      commits_synced_at: integration.commits_synced_at&.iso8601
    }
  end
end
```

**Note on `set_account`**: Check how the existing codebase resolves the current account. The Oura controller uses `Current.user` directly -- this controller needs account context. Look at how other account-scoped controllers resolve the account (likely via `session[:current_account_id]` or a `current_account` helper). Adapt accordingly.

### 5. Routes

- [ ] Add routes in `config/routes.rb`

```ruby
# GitHub integration (OAuth + settings)
resource :github_integration, only: %i[show create update destroy], controller: "github_integration" do
  get :callback
  get :select_repo
  post :save_repo
  post :sync
end
```

### 6. Frontend: Settings Page

- [ ] Create `app/frontend/pages/settings/github_integration.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Switch } from '$lib/components/shadcn/switch/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { GithubLogo, Link, LinkBreak, ArrowsClockwise } from 'phosphor-svelte';

  let { integration } = $props();
  let syncing = $state(false);

  function connect() {
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = '/github_integration';
    const csrf = document.createElement('input');
    csrf.type = 'hidden';
    csrf.name = 'authenticity_token';
    csrf.value = document.querySelector('meta[name="csrf-token"]')?.content || '';
    form.appendChild(csrf);
    document.body.appendChild(form);
    form.submit();
  }

  function disconnect() {
    if (confirm('Disconnect GitHub? Agents will no longer see commit history.')) {
      router.delete('/github_integration');
    }
  }

  function toggleEnabled(checked) {
    router.patch('/github_integration', { github_integration: { enabled: checked } });
  }

  function syncNow() {
    syncing = true;
    router.post('/github_integration/sync', {}, {
      onFinish: () => { syncing = false; }
    });
  }

  function changeRepo() {
    router.get('/github_integration/select_repo');
  }

  function formatSyncTime(isoString) {
    if (!isoString) return 'Never';
    return new Date(isoString).toLocaleString();
  }
</script>

<svelte:head>
  <title>GitHub Integration</title>
</svelte:head>

<div class="container mx-auto p-8 max-w-4xl">
  <div class="mb-8">
    <h1 class="text-3xl font-bold mb-2">GitHub Integration</h1>
    <p class="text-muted-foreground">
      Connect a GitHub repository so agents can see recent commit history.
    </p>
  </div>

  <div class="border rounded-lg p-6 mb-6">
    <div class="flex items-center justify-between mb-4">
      <div class="flex items-center gap-3">
        <div class="w-12 h-12 rounded-full bg-primary/10 flex items-center justify-center">
          <GithubLogo size={24} class="text-primary" />
        </div>
        <div>
          <h2 class="font-semibold">Connection Status</h2>
          <p class="text-sm text-muted-foreground">
            {#if integration.connected}
              <span class="text-green-600">Connected as {integration.github_username}</span>
              {#if integration.repository_full_name}
                &mdash; {integration.repository_full_name}
              {/if}
              {#if integration.commits_synced_at}
                <br />Last synced {formatSyncTime(integration.commits_synced_at)}
              {/if}
            {:else}
              <span class="text-muted-foreground">Not connected</span>
            {/if}
          </p>
        </div>
      </div>

      <div class="flex gap-2">
        {#if integration.connected}
          <Button variant="outline" onclick={changeRepo}>Change Repo</Button>
          <Button variant="outline" onclick={syncNow} disabled={syncing}>
            <ArrowsClockwise size={16} class={syncing ? 'mr-2 animate-spin' : 'mr-2'} />
            Sync
          </Button>
          <Button variant="destructive" onclick={disconnect}>
            <LinkBreak size={16} class="mr-2" />
            Disconnect
          </Button>
        {:else}
          <Button onclick={connect}>
            <Link size={16} class="mr-2" />
            Connect GitHub
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
          <Switch id="enabled" checked={integration.enabled} onCheckedChange={toggleEnabled} />
          <Label for="enabled">Share commit history with AI agents</Label>
        </div>
      </div>
      <p class="text-sm text-muted-foreground mt-4">
        When enabled, the last 10 commits are included in agent context, helping them understand
        what the team is working on.
      </p>
    </div>
  {/if}
</div>
```

### 7. Frontend: Repo Selection Page

- [ ] Create `app/frontend/pages/settings/github_select_repo.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { GithubLogo } from 'phosphor-svelte';

  let { repos, current_repo } = $props();
  let search = $state('');

  let filtered = $derived(
    repos.filter(r => r.full_name.toLowerCase().includes(search.toLowerCase()))
  );

  function selectRepo(fullName) {
    router.post('/github_integration/save_repo', { repository_full_name: fullName });
  }
</script>

<svelte:head>
  <title>Select Repository</title>
</svelte:head>

<div class="container mx-auto p-8 max-w-4xl">
  <div class="mb-8">
    <h1 class="text-3xl font-bold mb-2">Select a Repository</h1>
    <p class="text-muted-foreground">
      Choose which repository agents should track.
    </p>
  </div>

  <input
    type="text"
    bind:value={search}
    placeholder="Filter repositories..."
    class="input input-bordered w-full mb-6"
  />

  <div class="space-y-2">
    {#each filtered as repo}
      <button
        class="w-full text-left border rounded-lg p-4 hover:bg-accent transition-colors flex items-center justify-between"
        class:border-primary={repo.full_name === current_repo}
        onclick={() => selectRepo(repo.full_name)}
      >
        <div class="flex items-center gap-3">
          <GithubLogo size={20} />
          <span class="font-medium">{repo.full_name}</span>
          {#if repo.private}
            <span class="text-xs bg-muted px-2 py-0.5 rounded">Private</span>
          {/if}
        </div>
        {#if repo.full_name === current_repo}
          <span class="text-sm text-primary">Current</span>
        {/if}
      </button>
    {/each}

    {#if filtered.length === 0}
      <p class="text-muted-foreground text-center py-8">No repositories found.</p>
    {/if}
  </div>
</div>
```

### 8. Background Job: `SyncGithubCommitsJob`

- [ ] Create `app/jobs/sync_github_commits_job.rb`

```ruby
class SyncGithubCommitsJob < ApplicationJob
  queue_as :default

  retry_on GithubApi::Error, wait: :polynomially_longer, attempts: 3

  def perform(github_integration_id = nil)
    if github_integration_id
      GithubIntegration.find(github_integration_id).sync_commits!
    else
      GithubIntegration.needs_sync.find_each do |integration|
        SyncGithubCommitsJob.perform_later(integration.id)
      end
    end
  end
end
```

- [ ] Add recurring schedule in `config/recurring.yml` (or wherever Solid Queue recurring jobs are configured)

```yaml
sync_github_commits:
  class: SyncGithubCommitsJob
  schedule: every hour
```

### 9. Agent Context Injection

- [ ] Inject into `Chat#system_message_for` (after health context block, around line 502)

```ruby
if (github_context = account.github_commits_context)
  parts << github_context
end
```

- [ ] Inject into `Agent#build_initiation_prompt` (after `format_human_activity` section)

Add a `github_commits_section` method and include it in the prompt:

```ruby
def build_initiation_prompt(conversations:, recent_initiations:, human_activity:)
  <<~PROMPT
    #{system_prompt}

    #{memory_context}

    # Self-Initiated Decision
    ...existing content...

    # Recent Code Activity
    #{account.github_commits_context}

    ...rest of existing prompt...
  PROMPT
end
```

### 10. Credentials Setup

- [ ] Add GitHub OAuth credentials via `rails credentials:edit`

```yaml
github:
  client_id: <from GitHub OAuth App settings>
  client_secret: <from GitHub OAuth App settings>
```

- [ ] Register OAuth App at https://github.com/settings/applications/new with callback URL:
  - Development: `http://localhost:3100/github_integration/callback`
  - Production: `https://<production-domain>/github_integration/callback`

### 11. Testing Strategy

- [ ] **Model tests**: `GithubIntegration` validations, `commits_context` formatting, `disconnect!`
- [ ] **Controller tests**: OAuth flow (state validation, callback handling), repo selection, CRUD actions
- [ ] **Job tests**: `SyncGithubCommitsJob` with VCR cassettes for GitHub API calls
- [ ] **Integration test**: Full OAuth flow through to commit context appearing in agent system messages

Use VCR or WebMock to stub GitHub API responses in tests. Follow existing Oura test patterns.

### 12. Edge Cases and Error Handling

- **Token revocation**: GitHub API returns 401 -> clear access_token, mark disconnected
- **Repo deleted/inaccessible**: API returns 404 on commit fetch -> clear recent_commits, log warning
- **Rate limiting**: 5,000 requests/hour per token; handle 403 with `X-RateLimit-Remaining: 0`
- **Account with no integration**: `github_commits_context` returns nil gracefully
- **Multiple users connecting same account**: `uniqueness: true` on `account_id` prevents duplicates; `exchange_code!` updates existing record
- **Large repo lists**: Fetch up to 100 repos per page; for MVP this is sufficient. Add pagination later if needed.
