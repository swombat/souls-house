# AI-Friendly JSON API - Implementation Specification (Final)

**Plan ID:** 260115-01d
**Status:** Complete
**Date:** January 15, 2026

## Summary

A simplified JSON API for AI clients (Claude Code, etc.) to interact with conversations and whiteboards. This revision adds back the OAuth-style CLI key request flow while keeping all previous simplifications:

- **SHA256 token hashing** - Simple, fast indexed lookup instead of BCrypt prefix-based search
- **Fixed transcript passing** - Summary generation now correctly passes the transcript to the prompt template
- **Consistent prompt templates** - Variable names match what the code passes
- **OAuth-style CLI flow** - CLI tools can request API keys without manual copy/paste

**Target: ~500 lines Ruby, ~180 lines Svelte**

---

## Implementation Checklist

### Database
- [x] Generate migration for api_keys table
- [x] Generate migration for api_key_requests table
- [x] Generate migration to add summary fields to chats
- [x] Generate migration to add lock_version to whiteboards
- [x] Run migrations

### Models
- [x] Create `app/models/api_key.rb`
- [x] Create `app/models/api_key_request.rb`
- [x] Add `has_many :api_keys` to User model
- [x] Add summary methods to Chat model
- [x] Add transcript_for_api to Chat model
- [x] Update Chat json_attributes to include summary

### Prompt Template
- [x] Create `app/prompts/generate_summary/system.prompt.erb`
- [x] Create `app/prompts/generate_summary/user.prompt.erb`

### Controllers
- [x] Create `app/controllers/concerns/api_authentication.rb`
- [x] Create `app/controllers/api/v1/key_requests_controller.rb`
- [x] Create `app/controllers/api/v1/conversations_controller.rb`
- [x] Create `app/controllers/api/v1/whiteboards_controller.rb`
- [x] Create `app/controllers/api_keys_controller.rb`

### Routes
- [x] Add API routes to `config/routes.rb`
- [x] Add API key management routes
- [x] Add OAuth-style approval routes

### Frontend
- [x] Create `app/frontend/pages/api_keys/index.svelte`
- [x] Create `app/frontend/pages/api_keys/show.svelte`
- [x] Create `app/frontend/pages/api_keys/approve.svelte`
- [x] Create `app/frontend/pages/api_keys/approved.svelte`
- [x] ~Run `bin/rails js_from_routes:generate`~ (Not needed - routes auto-generated)

### Testing
- [x] ApiKey model tests
- [x] ApiKeyRequest model tests
- [x] Chat summary generation tests
- [x] API authentication tests
- [x] API controller tests
- [x] OAuth flow integration tests

---

## 1. Database Migrations

### Migration: API Keys

**File:** `db/migrate/[timestamp]_create_api_keys.rb`

```ruby
class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false, limit: 8
      t.datetime :last_used_at
      t.string :last_used_ip
      t.timestamps
    end

    add_index :api_keys, :token_digest, unique: true
  end
end
```

Note: We keep `token_prefix` for display purposes (`hx_abc1...`) but no longer need an index on it since SHA256 lookup is a single indexed query.

### Migration: API Key Requests

**File:** `db/migrate/[timestamp]_create_api_key_requests.rb`

```ruby
class CreateApiKeyRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :api_key_requests do |t|
      t.string :request_token, null: false
      t.string :client_name, null: false
      t.bigint :api_key_id
      t.string :status, null: false, default: 'pending'
      t.text :approved_token_encrypted
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :api_key_requests, :request_token, unique: true
    add_foreign_key :api_key_requests, :api_keys
  end
end
```

### Migration: Chat Summary Fields

**File:** `db/migrate/[timestamp]_add_summary_to_chats.rb`

```ruby
class AddSummaryToChats < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :summary, :text
    add_column :chats, :summary_generated_at, :datetime
  end
end
```

### Migration: Whiteboard Optimistic Locking

**File:** `db/migrate/[timestamp]_add_lock_version_to_whiteboards.rb`

```ruby
class AddLockVersionToWhiteboards < ActiveRecord::Migration[8.1]
  def change
    add_column :whiteboards, :lock_version, :integer, default: 0, null: false
  end
end
```

---

## 2. ApiKey Model

**File:** `app/models/api_key.rb`

```ruby
class ApiKey < ApplicationRecord
  TOKEN_PREFIX = "hx_"

  belongs_to :user

  validates :name, presence: true, length: { maximum: 100 }
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true

  scope :by_creation, -> { order(created_at: :desc) }

  def self.generate_for(user, name:)
    raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"

    key = create!(
      user: user,
      name: name,
      token_digest: Digest::SHA256.hexdigest(raw_token),
      token_prefix: raw_token[0, 8]
    )

    key.define_singleton_method(:raw_token) { raw_token }
    key
  end

  def self.authenticate(token)
    return nil if token.blank?
    find_by(token_digest: Digest::SHA256.hexdigest(token))
  end

  def touch_usage!(ip_address)
    update_columns(last_used_at: Time.current, last_used_ip: ip_address)
  end

  def display_prefix
    "#{token_prefix}..."
  end
end
```

Key changes from v2:
- **SHA256 instead of BCrypt** - Single indexed query for authentication
- **No prefix-based candidate filtering** - `authenticate` is now a simple `find_by`
- **Faster token verification** - No iterating through candidates

---

## 3. ApiKeyRequest Model

**File:** `app/models/api_key_request.rb`

```ruby
class ApiKeyRequest < ApplicationRecord
  EXPIRY_DURATION = 10.minutes

  belongs_to :api_key, optional: true

  validates :request_token, presence: true, uniqueness: true
  validates :client_name, presence: true, length: { maximum: 100 }
  validates :status, presence: true, inclusion: { in: %w[pending approved denied expired] }
  validates :expires_at, presence: true

  scope :pending, -> { where(status: "pending") }

  # Transient storage for the raw API key (encrypted in memory until CLI polls)
  attr_accessor :approved_raw_token

  def self.create_request(client_name:)
    create!(
      request_token: SecureRandom.urlsafe_base64(32),
      client_name: client_name,
      status: "pending",
      expires_at: EXPIRY_DURATION.from_now
    )
  end

  def approve!(user:, key_name:)
    transaction do
      api_key = ApiKey.generate_for(user, name: key_name)
      raw_token = api_key.raw_token

      # Store encrypted raw token temporarily for CLI retrieval
      update!(
        status: "approved",
        api_key: api_key,
        approved_token_encrypted: encrypt_token(raw_token)
      )

      api_key
    end
  end

  def retrieve_approved_token!
    return nil unless approved? && approved_token_encrypted.present?

    raw_token = decrypt_token(approved_token_encrypted)
    # Clear after retrieval for security
    update_column(:approved_token_encrypted, nil)
    raw_token
  end

  def deny!
    update!(status: "denied")
  end

  def status_for_client
    return "expired" if status == "pending" && expires_at < Time.current
    status
  end

  def expired?
    status_for_client == "expired"
  end

  def pending?
    status_for_client == "pending"
  end

  def approved?
    status == "approved"
  end

  def denied?
    status == "denied"
  end

  private

  def encrypt_token(token)
    Rails.application.message_verifier(:api_key_request).generate(token, expires_in: EXPIRY_DURATION)
  end

  def decrypt_token(encrypted)
    Rails.application.message_verifier(:api_key_request).verified(encrypted)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end
end
```

---

## 4. Model Extensions

### User Model

**File:** `app/models/user.rb` (add association)

```ruby
has_many :api_keys, dependent: :destroy
```

### Chat Model Extensions

**File:** `app/models/chat.rb` (additions)

Add to `json_attributes`:

```ruby
json_attributes :title_or_default, :model_id, :model_label, ..., :summary  # ADD summary
```

Add summary methods and transcript helper:

```ruby
SUMMARY_COOLDOWN = 1.hour
SUMMARY_MAX_WORDS = 200

def summary_stale?
  summary_generated_at.nil? || summary_generated_at < SUMMARY_COOLDOWN.ago
end

def generate_summary!
  return summary unless summary_stale?
  return nil if messages.where(role: %w[user assistant]).count < 2

  new_summary = generate_summary_from_llm
  update!(summary: new_summary, summary_generated_at: Time.current) if new_summary.present?
  summary
end

def transcript_for_api
  messages.includes(:user, :agent)
          .where(role: %w[user assistant])
          .order(:created_at)
          .map { |m| format_message_for_api(m) }
end

private

def generate_summary_from_llm
  transcript_lines = messages.where(role: %w[user assistant])
                             .order(:created_at)
                             .limit(20)
                             .map { |m| "#{m.role.titleize}: #{m.content.to_s.truncate(300)}" }

  return nil if transcript_lines.blank?

  prompt = Prompt.new(model: Prompt::LIGHT_MODEL, template: "generate_summary")
  response = prompt.render(messages: transcript_lines)
  prompt.execute_to_string&.squish&.truncate_words(SUMMARY_MAX_WORDS)
rescue StandardError => e
  Rails.logger.error "Summary generation failed: #{e.message}"
  nil
end

def format_message_for_api(message)
  {
    role: message.role,
    content: message.content,
    author: api_author_name(message),
    timestamp: message.created_at.iso8601
  }
end

def api_author_name(message)
  if message.agent.present?
    message.agent.name
  elsif message.user.present?
    message.user.full_name.presence || message.user.email_address.split("@").first
  else
    message.role.titleize
  end
end
```

Key changes from v2:
- **Fixed variable passing** - `transcript_lines` is an array, passed directly to `render()`
- **Template receives `messages` array** - Matches the pattern used in `generate_title`

---

## 5. Prompt Template for Summary

**File:** `app/prompts/generate_summary/system.prompt.erb`

```erb
You are a helpful assistant that writes concise conversation summaries.

Guidelines:
- Summarize the key topics and outcomes
- Keep under 200 words
- Write in third person, past tense
- Focus on what was discussed and any conclusions
- Be factual, not interpretive

Respond with the summary text only.
```

**File:** `app/prompts/generate_summary/user.prompt.erb`

```erb
Summarize this conversation:

<% if messages.blank? %>
No messages available.
<% else %>
<% messages.each do |line| %>
- <%= line %>
<% end %>
<% end %>
```

Key changes from v2:
- **Consistent with `generate_title` pattern** - Iterates over `messages` array
- **Same template structure** - Handles blank case explicitly

---

## 6. API Authentication Concern

**File:** `app/controllers/concerns/api_authentication.rb`

```ruby
module ApiAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_api_key!
  end

  private

  def authenticate_api_key!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    @current_api_key = ApiKey.authenticate(token)

    unless @current_api_key
      render json: { error: "Invalid or missing API key" }, status: :unauthorized
      return
    end

    @current_api_key.touch_usage!(request.remote_ip)
    Current.user = @current_api_key.user
  end

  def current_api_user
    @current_api_key&.user
  end

  def current_api_account
    current_api_user&.personal_account
  end
end
```

---

## 7. API Controllers

### Key Requests Controller (OAuth-style flow, NO auth required)

**File:** `app/controllers/api/v1/key_requests_controller.rb`

```ruby
module Api
  module V1
    class KeyRequestsController < ActionController::API
      def create
        request_record = ApiKeyRequest.create_request(client_name: params[:client_name])

        render json: {
          request_token: request_record.request_token,
          approval_url: approve_api_key_url(request_record.request_token),
          poll_url: api_v1_key_request_url(request_record.request_token),
          expires_at: request_record.expires_at.iso8601
        }, status: :created
      end

      def show
        request_record = ApiKeyRequest.find_by!(request_token: params[:id])

        response = {
          status: request_record.status_for_client,
          client_name: request_record.client_name
        }

        if request_record.approved?
          raw_token = request_record.retrieve_approved_token!
          if raw_token
            response[:api_key] = raw_token
            response[:user_email] = request_record.api_key.user.email_address
          end
        end

        render json: response
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Request not found" }, status: :not_found
      end
    end
  end
end
```

### Conversations Controller

**File:** `app/controllers/api/v1/conversations_controller.rb`

```ruby
module Api
  module V1
    class ConversationsController < ActionController::API
      include ApiAuthentication

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Not found" }, status: :not_found
      end

      def index
        chats = current_api_account.chats.kept.active.latest.limit(100)
        render json: { conversations: chats.map { |c| conversation_json(c) } }
      end

      def show
        chat = current_api_account.chats.find(params[:id])
        render json: {
          conversation: {
            id: chat.to_param,
            title: chat.title_or_default,
            model: chat.model_label,
            created_at: chat.created_at.iso8601,
            updated_at: chat.updated_at.iso8601,
            transcript: chat.transcript_for_api
          }
        }
      end

      def create_message
        chat = current_api_account.chats.find(params[:id])

        unless chat.respondable?
          return render json: { error: "Conversation is archived or deleted" }, status: :unprocessable_entity
        end

        message = chat.messages.create!(
          content: params[:content],
          role: "user",
          user: current_api_user
        )

        AiResponseJob.perform_later(chat) unless chat.manual_responses?

        render json: {
          message: { id: message.to_param, content: message.content, created_at: message.created_at.iso8601 },
          ai_response_triggered: !chat.manual_responses?
        }, status: :created
      end

      private

      def conversation_json(chat)
        {
          id: chat.to_param,
          title: chat.title_or_default,
          summary: chat.generate_summary!,
          model: chat.model_label,
          message_count: chat.message_count,
          updated_at: chat.updated_at.iso8601
        }
      end
    end
  end
end
```

### Whiteboards Controller

**File:** `app/controllers/api/v1/whiteboards_controller.rb`

```ruby
module Api
  module V1
    class WhiteboardsController < ActionController::API
      include ApiAuthentication

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Not found" }, status: :not_found
      end

      rescue_from ActiveRecord::StaleObjectError do
        render json: { error: "Whiteboard was modified by another user" }, status: :conflict
      end

      def index
        whiteboards = current_api_account.whiteboards.active.by_name
        render json: { whiteboards: whiteboards.map { |w| whiteboard_summary(w) } }
      end

      def show
        whiteboard = current_api_account.whiteboards.active.find(params[:id])
        render json: {
          whiteboard: {
            id: whiteboard.to_param,
            name: whiteboard.name,
            content: whiteboard.content,
            summary: whiteboard.summary,
            lock_version: whiteboard.lock_version,
            last_edited_at: whiteboard.last_edited_at&.iso8601,
            editor_name: whiteboard.editor_name
          }
        }
      end

      def update
        whiteboard = current_api_account.whiteboards.active.find(params[:id])

        whiteboard.lock_version = params[:lock_version] if params[:lock_version].present?
        whiteboard.update!(content: params[:content], last_edited_by: current_api_user)

        render json: { whiteboard: { id: whiteboard.to_param, lock_version: whiteboard.lock_version } }
      end

      private

      def whiteboard_summary(whiteboard)
        {
          id: whiteboard.to_param,
          name: whiteboard.name,
          summary: whiteboard.summary,
          content_length: whiteboard.content.to_s.length,
          lock_version: whiteboard.lock_version
        }
      end
    end
  end
end
```

---

## 8. Browser-Based API Key Management

### Controller

**File:** `app/controllers/api_keys_controller.rb`

```ruby
class ApiKeysController < ApplicationController
  before_action :set_key_request, only: [:approve, :confirm_approve, :deny]

  def index
    render inertia: "api_keys/index", props: {
      api_keys: Current.user.api_keys.by_creation.map { |k| api_key_json(k) }
    }
  end

  def create
    api_key = ApiKey.generate_for(Current.user, name: params[:name])

    render inertia: "api_keys/show", props: {
      api_key: api_key_json(api_key),
      raw_token: api_key.raw_token
    }
  end

  def destroy
    Current.user.api_keys.find(params[:id]).destroy!
    redirect_to api_keys_path, notice: "API key revoked"
  end

  # OAuth-style approval flow
  def approve
    if @key_request.expired?
      redirect_to api_keys_path, alert: "This request has expired"
      return
    end

    if @key_request.approved? || @key_request.denied?
      redirect_to api_keys_path, alert: "This request has already been processed"
      return
    end

    render inertia: "api_keys/approve", props: {
      client_name: @key_request.client_name,
      token: params[:token],
      expires_at: @key_request.expires_at.iso8601
    }
  end

  def confirm_approve
    if @key_request.expired? || !@key_request.pending?
      redirect_to api_keys_path, alert: "This request is no longer valid"
      return
    end

    key_name = params[:key_name].presence || "#{@key_request.client_name} Key"
    @key_request.approve!(user: Current.user, key_name: key_name)

    render inertia: "api_keys/approved", props: {
      client_name: @key_request.client_name
    }
  end

  def deny
    if @key_request.pending?
      @key_request.deny!
    end
    redirect_to api_keys_path, notice: "Request denied"
  end

  private

  def set_key_request
    @key_request = ApiKeyRequest.find_by!(request_token: params[:token])
  rescue ActiveRecord::RecordNotFound
    redirect_to api_keys_path, alert: "Invalid request"
  end

  def api_key_json(key)
    {
      id: key.id,
      name: key.name,
      prefix: key.display_prefix,
      created_at: key.created_at.strftime("%b %d, %Y"),
      last_used_at: key.last_used_at&.strftime("%b %d, %Y at %l:%M %p"),
      last_used_ip: key.last_used_ip
    }
  end
end
```

---

## 9. Routes

**File:** `config/routes.rb` (additions)

```ruby
resources :api_keys, only: [:index, :create, :destroy]
get "api_keys/approve/:token", to: "api_keys#approve", as: :approve_api_key
post "api_keys/approve/:token", to: "api_keys#confirm_approve"
delete "api_keys/approve/:token", to: "api_keys#deny", as: :deny_api_key

namespace :api do
  namespace :v1 do
    resources :key_requests, only: [:create, :show]
    resources :conversations, only: [:index, :show] do
      member do
        post :create_message
      end
    end
    resources :whiteboards, only: [:index, :show, :update]
  end
end
```

---

## 10. Frontend Components

### API Keys Index

**File:** `app/frontend/pages/api_keys/index.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { Key, Trash, Plus } from 'phosphor-svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';

  let { api_keys = [] } = $props();
  let newKeyName = $state('');
  let showForm = $state(false);

  function createKey() {
    if (newKeyName.trim()) {
      router.post('/api_keys', { name: newKeyName });
    }
  }

  function deleteKey(id) {
    if (confirm('Revoke this API key? Applications using it will stop working.')) {
      router.delete(`/api_keys/${id}`);
    }
  }
</script>

<div class="container mx-auto p-8 max-w-4xl">
  <div class="flex items-center justify-between mb-6">
    <div>
      <h1 class="text-2xl font-bold">API Keys</h1>
      <p class="text-muted-foreground">Manage API keys for CLI tools</p>
    </div>
    <Button onclick={() => showForm = !showForm}>
      <Plus class="mr-2" size={16} />
      Create Key
    </Button>
  </div>

  {#if showForm}
    <div class="mb-6 p-4 border rounded-lg">
      <form onsubmit|preventDefault={createKey} class="flex gap-2">
        <Input bind:value={newKeyName} placeholder="Key name (e.g., Claude Code)" class="flex-1" />
        <Button type="submit">Create</Button>
      </form>
    </div>
  {/if}

  <div class="border rounded-lg">
    {#if api_keys.length === 0}
      <div class="p-8 text-center text-muted-foreground">
        <Key size={48} class="mx-auto mb-4 opacity-50" />
        <p>No API keys yet. Create one to use with CLI tools.</p>
      </div>
    {:else}
      <div class="divide-y">
        {#each api_keys as key (key.id)}
          <div class="flex items-center justify-between p-4">
            <div>
              <div class="font-medium">{key.name}</div>
              <div class="text-sm text-muted-foreground">
                <code class="bg-muted px-1 rounded">{key.prefix}</code>
                <span class="mx-2">-</span>
                Created {key.created_at}
              </div>
              {#if key.last_used_at}
                <div class="text-xs text-muted-foreground mt-1">
                  Last used {key.last_used_at}
                </div>
              {/if}
            </div>
            <Button variant="ghost" size="icon" onclick={() => deleteKey(key.id)}>
              <Trash size={16} class="text-destructive" />
            </Button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
```

### API Key Show (displays new token)

**File:** `app/frontend/pages/api_keys/show.svelte`

```svelte
<script>
  import { Copy, Warning } from 'phosphor-svelte';
  import { Button } from '$lib/components/ui/button';

  let { api_key, raw_token } = $props();
  let copied = $state(false);

  async function copyToken() {
    await navigator.clipboard.writeText(raw_token);
    copied = true;
    setTimeout(() => copied = false, 2000);
  }
</script>

<div class="container mx-auto p-8 max-w-md">
  <div class="border rounded-lg p-6">
    <h1 class="text-xl font-bold mb-2">API Key Created</h1>
    <p class="text-muted-foreground mb-4">{api_key.name}</p>

    <div class="p-3 bg-amber-50 border border-amber-200 rounded mb-4 flex items-start gap-2">
      <Warning size={20} class="text-amber-600 mt-0.5" />
      <p class="text-sm text-amber-800">Copy this key now. You will not see it again.</p>
    </div>

    <div class="relative mb-4">
      <code class="block p-3 bg-muted rounded text-sm break-all pr-10">{raw_token}</code>
      <Button variant="ghost" size="icon" class="absolute top-1 right-1" onclick={copyToken}>
        <Copy size={16} />
      </Button>
    </div>

    {#if copied}
      <p class="text-sm text-green-600 mb-4">Copied to clipboard!</p>
    {/if}

    <Button href="/api_keys" variant="outline" class="w-full">Done</Button>
  </div>
</div>
```

### API Key Approval Page (OAuth flow)

**File:** `app/frontend/pages/api_keys/approve.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { ShieldCheck, X } from 'phosphor-svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Label } from '$lib/components/ui/label';

  let { client_name, token, expires_at } = $props();
  let keyName = $state(`${client_name} Key`);

  function approve() {
    router.post(`/api_keys/approve/${token}`, { key_name: keyName });
  }

  function deny() {
    router.delete(`/api_keys/approve/${token}`);
  }

  const expiresDate = new Date(expires_at);
  const timeRemaining = Math.max(0, Math.floor((expiresDate - new Date()) / 1000 / 60));
</script>

<div class="container mx-auto p-8 max-w-md">
  <div class="border rounded-lg p-6">
    <div class="flex items-center gap-3 mb-4">
      <div class="p-2 bg-blue-100 rounded-full">
        <ShieldCheck size={24} class="text-blue-600" />
      </div>
      <div>
        <h1 class="text-xl font-bold">Authorize Application</h1>
        <p class="text-sm text-muted-foreground">Expires in {timeRemaining} minutes</p>
      </div>
    </div>

    <div class="p-4 bg-muted rounded-lg mb-6">
      <p class="text-sm text-muted-foreground mb-1">Application requesting access:</p>
      <p class="font-semibold text-lg">{client_name}</p>
    </div>

    <div class="mb-6">
      <Label for="key-name">Key Name</Label>
      <Input id="key-name" bind:value={keyName} placeholder="Name for this API key" class="mt-1" />
      <p class="text-xs text-muted-foreground mt-1">You can use this name to identify and revoke the key later.</p>
    </div>

    <div class="flex gap-2">
      <Button onclick={approve} class="flex-1">
        <ShieldCheck class="mr-2" size={16} />
        Approve
      </Button>
      <Button variant="outline" onclick={deny} class="flex-1">
        <X class="mr-2" size={16} />
        Deny
      </Button>
    </div>
  </div>
</div>
```

### API Key Approved Success Page

**File:** `app/frontend/pages/api_keys/approved.svelte`

```svelte
<script>
  import { CheckCircle } from 'phosphor-svelte';
  import { Button } from '$lib/components/ui/button';

  let { client_name } = $props();
</script>

<div class="container mx-auto p-8 max-w-md">
  <div class="border rounded-lg p-6 text-center">
    <div class="mx-auto w-16 h-16 bg-green-100 rounded-full flex items-center justify-center mb-4">
      <CheckCircle size={32} class="text-green-600" weight="fill" />
    </div>

    <h1 class="text-xl font-bold mb-2">Access Granted</h1>
    <p class="text-muted-foreground mb-6">
      <strong>{client_name}</strong> has been authorized.<br />
      You can close this tab and return to your CLI.
    </p>

    <Button href="/api_keys" variant="outline" class="w-full">
      Manage API Keys
    </Button>
  </div>
</div>
```

---

## 11. Testing Strategy

### Model Tests

**File:** `test/models/api_key_test.rb`

```ruby
require "test_helper"

class ApiKeyTest < ActiveSupport::TestCase
  setup do
    @user = users(:confirmed_user)
  end

  test "generates key with correct prefix" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    assert key.raw_token.start_with?("hx_")
  end

  test "authenticates valid token" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    raw_token = key.raw_token

    assert_equal key, ApiKey.authenticate(raw_token)
  end

  test "rejects invalid token" do
    assert_nil ApiKey.authenticate("invalid")
    assert_nil ApiKey.authenticate(nil)
    assert_nil ApiKey.authenticate("")
  end

  test "raw_token only available immediately after creation" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    assert key.raw_token.present?

    reloaded = ApiKey.find(key.id)
    assert_raises(NoMethodError) { reloaded.raw_token }
  end

  test "stores SHA256 digest not raw token" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    raw_token = key.raw_token

    assert_equal Digest::SHA256.hexdigest(raw_token), key.token_digest
  end
end
```

**File:** `test/models/api_key_request_test.rb`

```ruby
require "test_helper"

class ApiKeyRequestTest < ActiveSupport::TestCase
  setup do
    @user = users(:confirmed_user)
  end

  test "creates request with pending status" do
    request = ApiKeyRequest.create_request(client_name: "Claude Code")
    assert_equal "pending", request.status
    assert request.request_token.present?
    assert request.expires_at > Time.current
  end

  test "approving creates api key and stores encrypted token" do
    request = ApiKeyRequest.create_request(client_name: "Claude Code")
    api_key = request.approve!(user: @user, key_name: "Test Key")

    assert_equal "approved", request.reload.status
    assert_equal api_key, request.api_key
    assert request.approved_token_encrypted.present?
  end

  test "retrieve_approved_token returns token once" do
    request = ApiKeyRequest.create_request(client_name: "Claude Code")
    api_key = request.approve!(user: @user, key_name: "Test Key")

    token = request.retrieve_approved_token!
    assert token.start_with?("hx_")

    # Second retrieval returns nil
    assert_nil request.retrieve_approved_token!
  end

  test "expired request returns expired status" do
    request = ApiKeyRequest.create_request(client_name: "Claude Code")
    request.update_column(:expires_at, 1.minute.ago)

    assert_equal "expired", request.status_for_client
    assert request.expired?
  end

  test "deny changes status" do
    request = ApiKeyRequest.create_request(client_name: "Claude Code")
    request.deny!

    assert_equal "denied", request.status
  end
end
```

### Controller Tests

**File:** `test/controllers/api/v1/key_requests_controller_test.rb`

```ruby
require "test_helper"

module Api
  module V1
    class KeyRequestsControllerTest < ActionDispatch::IntegrationTest
      test "creates key request" do
        post api_v1_key_requests_url, params: { client_name: "Claude Code" }
        assert_response :created

        json = JSON.parse(response.body)
        assert json["request_token"].present?
        assert json["approval_url"].present?
        assert json["poll_url"].present?
      end

      test "shows pending request status" do
        request = ApiKeyRequest.create_request(client_name: "Claude Code")
        get api_v1_key_request_url(request.request_token)

        json = JSON.parse(response.body)
        assert_equal "pending", json["status"]
        assert_equal "Claude Code", json["client_name"]
      end

      test "shows approved request with token" do
        user = users(:confirmed_user)
        request = ApiKeyRequest.create_request(client_name: "Claude Code")
        request.approve!(user: user, key_name: "Test")

        get api_v1_key_request_url(request.request_token)

        json = JSON.parse(response.body)
        assert_equal "approved", json["status"]
        assert json["api_key"].start_with?("hx_")
        assert_equal user.email_address, json["user_email"]
      end

      test "expired request returns expired status" do
        request = ApiKeyRequest.create_request(client_name: "Claude Code")
        request.update_column(:expires_at, 1.minute.ago)

        get api_v1_key_request_url(request.request_token)

        json = JSON.parse(response.body)
        assert_equal "expired", json["status"]
      end
    end
  end
end
```

**File:** `test/controllers/api/v1/conversations_controller_test.rb`

```ruby
require "test_helper"

module Api
  module V1
    class ConversationsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @user = users(:confirmed_user)
        @api_key = ApiKey.generate_for(@user, name: "Test")
        @token = @api_key.raw_token
        @account = @user.personal_account
        @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Test")
      end

      test "lists conversations with valid token" do
        get api_v1_conversations_url, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success
      end

      test "returns unauthorized without token" do
        get api_v1_conversations_url
        assert_response :unauthorized
      end

      test "creates message and triggers AI" do
        @chat.messages.create!(content: "Hello", role: "user", user: @user)

        assert_enqueued_with(job: AiResponseJob) do
          post create_message_api_v1_conversation_url(@chat),
               params: { content: "New message" },
               headers: { "Authorization" => "Bearer #{@token}" }
        end
        assert_response :created
      end
    end
  end
end
```

---

## API Documentation

### Authentication

All requests (except key requests) require a Bearer token:

```
Authorization: Bearer hx_your_api_key_here
```

### Key Request Endpoints (No auth required)

#### Request API Key Authorization
```
POST /api/v1/key_requests
Content-Type: application/json

{ "client_name": "Claude Code" }

Response:
{
  "request_token": "abc123...",
  "approval_url": "https://app.example.com/api_keys/approve/abc123...",
  "poll_url": "https://app.example.com/api/v1/key_requests/abc123...",
  "expires_at": "2026-01-15T10:40:00Z"
}
```

#### Poll Authorization Status
```
GET /api/v1/key_requests/:request_token

Response (pending):
{ "status": "pending", "client_name": "Claude Code" }

Response (approved):
{
  "status": "approved",
  "client_name": "Claude Code",
  "api_key": "hx_...",
  "user_email": "user@example.com"
}

Response (denied):
{ "status": "denied", "client_name": "Claude Code" }

Response (expired):
{ "status": "expired", "client_name": "Claude Code" }
```

### Authenticated Endpoints

#### List Conversations
```
GET /api/v1/conversations

Response:
{
  "conversations": [
    {
      "id": "abc123",
      "title": "Project Planning",
      "summary": "Discussed Q1 roadmap priorities...",
      "model": "GPT-5",
      "message_count": 24,
      "updated_at": "2026-01-15T10:30:00Z"
    }
  ]
}
```

#### Get Conversation
```
GET /api/v1/conversations/:id

Response:
{
  "conversation": {
    "id": "abc123",
    "title": "Project Planning",
    "model": "GPT-5",
    "created_at": "2026-01-15T09:00:00Z",
    "updated_at": "2026-01-15T10:30:00Z",
    "transcript": [
      { "role": "user", "content": "...", "author": "Daniel", "timestamp": "..." },
      { "role": "assistant", "content": "...", "author": "GPT-5", "timestamp": "..." }
    ]
  }
}
```

#### Post Message
```
POST /api/v1/conversations/:id/create_message
Content-Type: application/json

{ "content": "Your message here" }

Response:
{
  "message": { "id": "xyz789", "content": "...", "created_at": "..." },
  "ai_response_triggered": true
}
```

#### List Whiteboards
```
GET /api/v1/whiteboards

Response:
{
  "whiteboards": [
    {
      "id": "wb123",
      "name": "Meeting Notes",
      "summary": "Notes from team meetings",
      "content_length": 4500,
      "lock_version": 3
    }
  ]
}
```

#### Get Whiteboard
```
GET /api/v1/whiteboards/:id
```

#### Update Whiteboard
```
PATCH /api/v1/whiteboards/:id
Content-Type: application/json

{
  "content": "New content",
  "lock_version": 3
}

Response (success):
{ "whiteboard": { "id": "wb123", "lock_version": 4 } }

Response (conflict - 409):
{ "error": "Whiteboard was modified by another user" }
```
