# AI-Friendly JSON API - Implementation Specification (v2)

**Plan ID:** 260115-01b
**Status:** Ready for Implementation
**Date:** January 15, 2026

## Summary

A simplified JSON API for AI clients (Claude Code, etc.) to interact with conversations and whiteboards. This revision applies DHH's feedback to dramatically reduce complexity:

- **No OAuth flow** - Browser-based key creation only
- **No prompt class** - Summary generation lives in the Chat model
- **No base controller** - Include concern directly in each controller
- **Rails built-in locking** - Use `lock_version` for whiteboard conflicts

**Target: ~300 lines Ruby, ~100 lines Svelte**

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
    add_index :api_keys, :token_prefix
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
      token_digest: BCrypt::Password.create(raw_token),
      token_prefix: raw_token[0, 8]
    )

    key.define_singleton_method(:raw_token) { raw_token }
    key
  end

  def self.authenticate(token)
    return nil if token.blank?

    candidates = where(token_prefix: token[0, 8])
    candidates.find { |k| BCrypt::Password.new(k.token_digest) == token }
  end

  def touch_usage!(ip_address)
    update_columns(last_used_at: Time.current, last_used_ip: ip_address)
  end

  def display_prefix
    "#{token_prefix}..."
  end
end
```

---

## 3. Model Extensions

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
  transcript = messages.where(role: %w[user assistant])
                       .order(:created_at)
                       .limit(20)
                       .map { |m| "#{m.role.titleize}: #{m.content.to_s.truncate(300)}" }
                       .join("\n")

  return nil if transcript.blank?

  prompt = Prompt.new(model: Prompt::LIGHT_MODEL, template: "generate_summary")
  response = prompt.execute_to_string
  response&.squish&.truncate_words(SUMMARY_MAX_WORDS)
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

---

## 4. Prompt Template for Summary

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

<%= messages %>
```

---

## 5. API Authentication Concern

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

## 6. API Controllers

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

## 7. Browser-Based API Key Management

### Controller

**File:** `app/controllers/api_keys_controller.rb`

```ruby
class ApiKeysController < ApplicationController
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

  private

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

## 8. Routes

**File:** `config/routes.rb` (additions)

```ruby
resources :api_keys, only: [:index, :create, :destroy]

namespace :api do
  namespace :v1 do
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

## 9. Frontend Components

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

---

## 10. Implementation Checklist

### Database
- [ ] Generate migration for api_keys table
- [ ] Generate migration to add summary fields to chats
- [ ] Generate migration to add lock_version to whiteboards
- [ ] Run migrations

### Models
- [ ] Create `app/models/api_key.rb`
- [ ] Add `has_many :api_keys` to User model
- [ ] Add summary methods to Chat model
- [ ] Add transcript_for_api to Chat model
- [ ] Update Chat json_attributes to include summary

### Prompt Template
- [ ] Create `app/prompts/generate_summary/system.prompt.erb`
- [ ] Create `app/prompts/generate_summary/user.prompt.erb`

### Controllers
- [ ] Create `app/controllers/concerns/api_authentication.rb`
- [ ] Create `app/controllers/api/v1/conversations_controller.rb`
- [ ] Create `app/controllers/api/v1/whiteboards_controller.rb`
- [ ] Create `app/controllers/api_keys_controller.rb`

### Routes
- [ ] Add API routes to `config/routes.rb`
- [ ] Add API key management routes

### Frontend
- [ ] Create `app/frontend/pages/api_keys/index.svelte`
- [ ] Create `app/frontend/pages/api_keys/show.svelte`
- [ ] Run `bin/rails js_from_routes:generate`

### Testing
- [ ] ApiKey model tests
- [ ] Chat summary generation tests
- [ ] API authentication tests
- [ ] API controller tests

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
    assert_nil reloaded.raw_token rescue NoMethodError
  end
end
```

### Controller Tests

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

## 12. API Documentation

### Authentication

All requests require a Bearer token:

```
Authorization: Bearer hx_your_api_key_here
```

### Endpoints

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

---

## 13. Code Summary

| Component | Lines | File |
|-----------|-------|------|
| Migrations (3) | ~30 | `db/migrate/*` |
| ApiKey model | ~40 | `app/models/api_key.rb` |
| Chat model additions | ~45 | `app/models/chat.rb` |
| User model additions | 1 | `app/models/user.rb` |
| Prompt templates | ~15 | `app/prompts/generate_summary/*` |
| ApiAuthentication concern | ~25 | `app/controllers/concerns/*` |
| API controllers (2) | ~100 | `app/controllers/api/v1/*` |
| ApiKeysController | ~30 | `app/controllers/api_keys_controller.rb` |
| Routes | ~10 | `config/routes.rb` |
| Frontend pages (2) | ~100 | `app/frontend/pages/api_keys/*` |
| **Total** | **~400** | |

---

## 14. What We Removed (per DHH feedback)

1. **ApiKeyRequest model and OAuth flow** (~150 lines saved)
   - No polling endpoints
   - No browser approval pages
   - No expiration/cleanup logic

2. **GenerateSummaryPrompt class** (~50 lines saved)
   - Summary generation is now a private method in Chat
   - Uses existing Prompt base class directly

3. **Api::V1::BaseController** (~20 lines saved)
   - Include ApiAuthentication concern directly in each controller
   - Extract a base class later when there are 10+ API controllers

4. **Manual revision checking for whiteboards**
   - Using Rails built-in `lock_version` optimistic locking
   - Cleaner error handling via `ActiveRecord::StaleObjectError`

---

## 15. Future Considerations (Add When Needed)

- OAuth-style CLI key request flow (when users demand it)
- Rate limiting for API endpoints
- Scoped API keys (read-only, specific resources)
- API key expiration dates
- Team account access
- OpenAPI documentation generation
