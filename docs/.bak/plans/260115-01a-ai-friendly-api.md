# AI-Friendly JSON API - Implementation Specification

**Plan ID:** 260115-01a
**Status:** Ready for Implementation
**Date:** January 15, 2026

## Summary

Implement a JSON API designed for AI clients (Claude Code, etc.) to interact with the application. Features include:

- **API Key Authentication**: OAuth-style flow where CLI requests key approval via browser
- **Conversation Access**: List conversations with summaries, retrieve full transcripts
- **Whiteboard Access**: List and update whiteboards
- **Message Posting**: Post messages on behalf of users, with AI response triggering in 1-1 chats

The API is lightweight compared to MCP, requiring only HTTP requests and a one-time browser-based key approval.

**Total new code: ~600 lines**

---

## 1. Database Design

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
    add_index :api_keys, [:user_id, :created_at]
  end
end
```

### Migration: Chat Summary

**File:** `db/migrate/[timestamp]_add_summary_to_chats.rb`

```ruby
class AddSummaryToChats < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :summary, :text
    add_column :chats, :summary_generated_at, :datetime
    add_index :chats, :summary_generated_at
  end
end
```

### Migration: API Key Requests (for OAuth-style flow)

**File:** `db/migrate/[timestamp]_create_api_key_requests.rb`

```ruby
class CreateApiKeyRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :api_key_requests do |t|
      t.string :request_token, null: false
      t.string :client_name, null: false
      t.bigint :api_key_id
      t.string :status, null: false, default: 'pending'
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :api_key_requests, :request_token, unique: true
    add_index :api_key_requests, :status
    add_index :api_key_requests, :expires_at
    add_foreign_key :api_key_requests, :api_keys
  end
end
```

Design rationale:
- `token_digest`: Store bcrypt hash, never the raw token (security)
- `token_prefix`: Store first 8 chars for display ("sk_abc1..." style identification)
- `api_key_requests`: Temporary records for OAuth-style flow, auto-expire
- `summary_generated_at`: Prevents regeneration more than once per hour

---

## 2. Model Implementation

### ApiKey Model

**File:** `app/models/api_key.rb`

```ruby
class ApiKey < ApplicationRecord
  TOKEN_PREFIX = "hx_"

  belongs_to :user

  has_secure_token :token, length: 32

  validates :name, presence: true, length: { maximum: 100 }
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true

  before_validation :set_token_fields, on: :create

  scope :recently_used, -> { order(last_used_at: :desc) }
  scope :by_creation, -> { order(created_at: :desc) }

  # Generate and return a new key, caching the raw token temporarily
  def self.generate_for(user, name:)
    raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"

    key = new(
      user: user,
      name: name,
      token_digest: BCrypt::Password.create(raw_token),
      token_prefix: raw_token[0, 8]
    )

    # Store raw token for one-time retrieval after creation
    key.instance_variable_set(:@raw_token, raw_token)
    key.save!
    key
  end

  # One-time access to raw token (only available immediately after creation)
  def raw_token
    @raw_token
  end

  # Authenticate a token and return the ApiKey if valid
  def self.authenticate(token)
    return nil if token.blank?

    # Quick filter by prefix for performance
    prefix = token[0, 8]
    candidates = where(token_prefix: prefix)

    candidates.find do |key|
      BCrypt::Password.new(key.token_digest) == token
    end
  end

  def touch_usage!(ip_address)
    update_columns(last_used_at: Time.current, last_used_ip: ip_address)
  end

  def display_prefix
    "#{token_prefix}..."
  end

  private

  def set_token_fields
    # Only used as fallback if generate_for wasn't used
    return if token_digest.present?

    raw = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"
    self.token_digest = BCrypt::Password.create(raw)
    self.token_prefix = raw[0, 8]
    @raw_token = raw
  end
end
```

### ApiKeyRequest Model (OAuth-style flow)

**File:** `app/models/api_key_request.rb`

```ruby
class ApiKeyRequest < ApplicationRecord
  REQUEST_EXPIRY = 10.minutes

  belongs_to :api_key, optional: true

  validates :request_token, presence: true, uniqueness: true
  validates :client_name, presence: true, length: { maximum: 100 }
  validates :status, inclusion: { in: %w[pending approved denied expired] }

  scope :pending, -> { where(status: 'pending') }
  scope :not_expired, -> { where('expires_at > ?', Time.current) }

  before_validation :generate_request_token, on: :create
  before_validation :set_expiry, on: :create

  def self.create_request(client_name:)
    create!(client_name: client_name)
  end

  def approve!(user:, key_name:)
    return false unless pending? && !expired?

    transaction do
      api_key = ApiKey.generate_for(user, name: key_name)
      update!(status: 'approved', api_key: api_key)
      api_key
    end
  end

  def deny!
    update!(status: 'denied') if pending?
  end

  def pending?
    status == 'pending'
  end

  def approved?
    status == 'approved'
  end

  def expired?
    expires_at < Time.current
  end

  # For CLI polling
  def status_for_client
    return 'expired' if pending? && expired?
    status
  end

  private

  def generate_request_token
    self.request_token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiry
    self.expires_at ||= REQUEST_EXPIRY.from_now
  end
end
```

### Chat Model Extensions

**File:** `app/models/chat.rb` (additions)

Add to `json_attributes`:

```ruby
json_attributes :title_or_default, :model_id, :model_label, :ai_model_name, :updated_at_formatted,
                :updated_at_short, :message_count, :total_tokens, :web_access, :manual_responses,
                :participants_json, :archived_at, :discarded_at, :archived, :discarded, :respondable,
                :summary  # ADD THIS
```

Add summary methods:

```ruby
SUMMARY_COOLDOWN = 1.hour
SUMMARY_MAX_LENGTH = 200

def summary_stale?
  summary_generated_at.nil? || summary_generated_at < SUMMARY_COOLDOWN.ago
end

def generate_summary!
  return summary unless summary_stale?
  return nil if messages.count < 2

  new_summary = GenerateSummaryPrompt.new(chat: self).generate_summary
  update!(summary: new_summary, summary_generated_at: Time.current) if new_summary.present?
  summary
end

def transcript_for_api
  messages.includes(:user, :agent)
          .order(:created_at)
          .where(role: %w[user assistant])
          .map { |m| format_message_for_transcript(m) }
end

private

def format_message_for_transcript(message)
  {
    role: message.role,
    content: message.content,
    author: message_author_name(message),
    timestamp: message.created_at.iso8601
  }
end

def message_author_name(message)
  if message.agent.present?
    message.agent.name
  elsif message.user.present?
    message.user.full_name.presence || message.user.email_address.split('@').first
  else
    message.role.titleize
  end
end
```

### User Model Extensions

**File:** `app/models/user.rb` (additions)

```ruby
has_many :api_keys, dependent: :destroy
```

---

## 3. Summary Generation Prompt

### GenerateSummaryPrompt

**File:** `app/prompts/generate_summary_prompt.rb`

```ruby
class GenerateSummaryPrompt < Prompt
  MAX_MESSAGES = 20
  MAX_MESSAGE_LENGTH = 300

  def initialize(chat:, model: Prompt::LIGHT_MODEL)
    super(model: model, template: "generate_summary")
    @chat = chat
  end

  def generate_summary
    response = execute_to_string
    extract_summary(response)&.truncate(Chat::SUMMARY_MAX_LENGTH)&.squish
  end

  private

  attr_reader :chat

  def render(**args)
    conversation_lines = build_conversation_lines
    super(**{ messages: conversation_lines, title: chat.title }.merge(args))
  end

  def build_conversation_lines
    chat.messages
        .where(role: %w[user assistant])
        .order(:created_at)
        .limit(MAX_MESSAGES)
        .map { |message| format_message_line(message) }
        .compact
  end

  def format_message_line(message)
    content = message.content.to_s.strip
    return if content.blank?

    label = message.role == "user" ? "User" : "Assistant"
    truncated_content = content.truncate(MAX_MESSAGE_LENGTH)
    "#{label}: #{truncated_content}"
  end

  def extract_summary(response)
    return if response.blank?
    response.is_a?(Hash) ? response.dig("choices", 0, "message", "content") : response
  end
end
```

### Prompt Templates

**File:** `app/prompts/generate_summary/system.prompt.erb`

```erb
You are a helpful assistant that writes concise conversation summaries for AI tools.

Guidelines:
- Summarize the key topics and outcomes of the conversation
- Keep the summary under 200 words
- Write in third person, past tense
- Focus on what was discussed and any decisions or conclusions reached
- Be factual, not interpretive
- Do not include greetings or pleasantries

Respond with the summary text only.
```

**File:** `app/prompts/generate_summary/user.prompt.erb`

```erb
Summarize the following conversation:
<% if title.present? %>

Title: <%= title %>
<% end %>

Transcript:
<% if messages.blank? %>
- No messages available.
<% else %>
<% messages.each do |line| %>
- <%= line %>
<% end %>
<% end %>

Summary:
```

---

## 4. API Authentication Concern

**File:** `app/controllers/concerns/api_authentication.rb`

```ruby
module ApiAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_api_key!
  end

  private

  def authenticate_api_key!
    token = extract_bearer_token
    @current_api_key = ApiKey.authenticate(token)

    unless @current_api_key
      render json: { error: "Invalid or missing API key" }, status: :unauthorized
      return
    end

    @current_api_key.touch_usage!(request.remote_ip)
    Current.user = @current_api_key.user
  end

  def extract_bearer_token
    auth_header = request.headers["Authorization"]
    return nil unless auth_header&.start_with?("Bearer ")
    auth_header.sub("Bearer ", "")
  end

  def current_api_user
    @current_api_key&.user
  end

  def current_api_account
    # API always operates on user's personal account
    current_api_user&.personal_account
  end
end
```

---

## 5. API Controllers

### Base API Controller

**File:** `app/controllers/api/v1/base_controller.rb`

```ruby
module Api
  module V1
    class BaseController < ActionController::API
      include ApiAuthentication

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity

      private

      def not_found
        render json: { error: "Record not found" }, status: :not_found
      end

      def unprocessable_entity(exception)
        render json: { error: exception.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
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
    class ConversationsController < BaseController
      def index
        chats = current_api_account.chats.kept.active.latest.limit(100)

        render json: {
          conversations: chats.map { |c| conversation_summary(c) }
        }
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
            participants: chat.participants_json,
            whiteboard: whiteboard_info(chat.active_whiteboard),
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

        # Trigger AI response only in 1-1 chats (not group chats)
        unless chat.manual_responses?
          AiResponseJob.perform_later(chat)
        end

        render json: {
          message: {
            id: message.to_param,
            content: message.content,
            role: message.role,
            created_at: message.created_at.iso8601
          },
          ai_response_triggered: !chat.manual_responses?
        }, status: :created
      end

      private

      def conversation_summary(chat)
        {
          id: chat.to_param,
          title: chat.title_or_default,
          summary: chat.generate_summary!,
          model: chat.model_label,
          message_count: chat.message_count,
          participants: chat.participants_json,
          whiteboard: whiteboard_info(chat.active_whiteboard),
          updated_at: chat.updated_at.iso8601
        }
      end

      def whiteboard_info(whiteboard)
        return nil unless whiteboard && !whiteboard.deleted?

        {
          id: whiteboard.to_param,
          name: whiteboard.name,
          summary: whiteboard.summary
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
    class WhiteboardsController < BaseController
      def index
        whiteboards = current_api_account.whiteboards.active.by_name

        render json: {
          whiteboards: whiteboards.map { |w| whiteboard_summary(w) }
        }
      end

      def show
        whiteboard = current_api_account.whiteboards.active.find(params[:id])

        render json: {
          whiteboard: {
            id: whiteboard.to_param,
            name: whiteboard.name,
            content: whiteboard.content,
            summary: whiteboard.summary,
            revision: whiteboard.revision,
            last_edited_at: whiteboard.last_edited_at&.iso8601,
            editor_name: whiteboard.editor_name
          }
        }
      end

      def update
        whiteboard = current_api_account.whiteboards.active.find(params[:id])

        # Optimistic locking via revision check
        if params[:expected_revision].present? && whiteboard.revision != params[:expected_revision].to_i
          return render json: {
            error: "conflict",
            message: "Whiteboard has been modified",
            current_revision: whiteboard.revision
          }, status: :conflict
        end

        whiteboard.update!(
          content: params[:content],
          last_edited_by: current_api_user
        )

        render json: {
          whiteboard: {
            id: whiteboard.to_param,
            revision: whiteboard.revision
          }
        }
      end

      private

      def whiteboard_summary(whiteboard)
        {
          id: whiteboard.to_param,
          name: whiteboard.name,
          summary: whiteboard.summary,
          content_length: whiteboard.content.to_s.length,
          revision: whiteboard.revision,
          last_edited_at: whiteboard.last_edited_at&.iso8601
        }
      end
    end
  end
end
```

---

## 6. OAuth-Style Key Request Flow

### API Key Requests Controller (for CLI)

**File:** `app/controllers/api/v1/key_requests_controller.rb`

```ruby
module Api
  module V1
    class KeyRequestsController < ActionController::API
      # No authentication required - this is the bootstrap flow

      # CLI calls this to initiate key request
      def create
        request = ApiKeyRequest.create_request(client_name: params[:client_name] || "CLI Client")

        render json: {
          request_token: request.request_token,
          approval_url: approve_api_key_url(request.request_token),
          poll_url: api_v1_key_request_url(request.request_token),
          expires_at: request.expires_at.iso8601
        }, status: :created
      end

      # CLI polls this to check status
      def show
        request = ApiKeyRequest.find_by!(request_token: params[:id])

        response = {
          status: request.status_for_client,
          client_name: request.client_name
        }

        if request.approved? && request.api_key
          response[:api_key] = request.api_key.raw_token
          response[:user_email] = request.api_key.user.email_address
        end

        render json: response
      end
    end
  end
end
```

### Browser-Based Approval Controller

**File:** `app/controllers/api_keys_controller.rb`

```ruby
class ApiKeysController < ApplicationController
  before_action :set_api_key_request, only: [:approve, :confirm_approve, :deny]

  # List user's API keys
  def index
    @api_keys = Current.user.api_keys.by_creation

    render inertia: "api_keys/index", props: {
      api_keys: @api_keys.map { |k| api_key_json(k) }
    }
  end

  # Manual key creation (fallback flow)
  def new
    render inertia: "api_keys/new", props: {}
  end

  def create
    @api_key = ApiKey.generate_for(Current.user, name: params[:name])

    render inertia: "api_keys/show", props: {
      api_key: api_key_json(@api_key),
      raw_token: @api_key.raw_token,
      show_token_warning: true
    }
  end

  def destroy
    @api_key = Current.user.api_keys.find(params[:id])
    @api_key.destroy!
    redirect_to api_keys_path, notice: "API key revoked"
  end

  # OAuth-style approval page (opened in browser from CLI)
  def approve
    if @request.expired?
      return redirect_to api_keys_path, alert: "This key request has expired"
    end

    unless @request.pending?
      return redirect_to api_keys_path, alert: "This request has already been processed"
    end

    render inertia: "api_keys/approve", props: {
      request: {
        client_name: @request.client_name,
        request_token: @request.request_token,
        expires_at: @request.expires_at.iso8601
      }
    }
  end

  def confirm_approve
    if @request.expired? || !@request.pending?
      return redirect_to api_keys_path, alert: "This request is no longer valid"
    end

    key_name = params[:name].presence || @request.client_name
    @api_key = @request.approve!(user: Current.user, key_name: key_name)

    render inertia: "api_keys/approved", props: {
      message: "API key created! You can close this window and return to your CLI."
    }
  end

  def deny
    @request.deny!
    redirect_to api_keys_path, notice: "Request denied"
  end

  private

  def set_api_key_request
    @request = ApiKeyRequest.find_by!(request_token: params[:token])
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

## 7. Routes

**File:** `config/routes.rb` (additions)

```ruby
# API Key management (browser-based)
resources :api_keys, only: [:index, :new, :create, :destroy]
get "api_keys/approve/:token", to: "api_keys#approve", as: :approve_api_key
post "api_keys/approve/:token", to: "api_keys#confirm_approve"
delete "api_keys/approve/:token", to: "api_keys#deny", as: :deny_api_key

# JSON API
namespace :api do
  namespace :v1 do
    # Key request flow (no auth required)
    resources :key_requests, only: [:create, :show]

    # Authenticated endpoints
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

## 8. Frontend Components

### API Keys Index Page

**File:** `app/frontend/pages/api_keys/index.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { Key, Trash, Plus, Copy } from 'phosphor-svelte';
  import Layout from '@/layouts/layout.svelte';
  import { Button } from '@/lib/components/ui/button';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/lib/components/ui/card';

  let { api_keys = [] } = $props();

  function deleteKey(id) {
    if (confirm('Revoke this API key? Any applications using it will stop working.')) {
      router.delete(`/api_keys/${id}`);
    }
  }
</script>

<Layout title="API Keys">
  <div class="container max-w-4xl py-8">
    <div class="flex items-center justify-between mb-6">
      <div>
        <h1 class="text-2xl font-bold">API Keys</h1>
        <p class="text-muted-foreground">Manage API keys for CLI and automation tools</p>
      </div>
      <Button href="/api_keys/new">
        <Plus class="mr-2" size={16} />
        Create Key
      </Button>
    </div>

    <Card>
      <CardContent class="p-0">
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
                      Last used {key.last_used_at} from {key.last_used_ip}
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
      </CardContent>
    </Card>
  </div>
</Layout>
```

### API Key Creation Page

**File:** `app/frontend/pages/api_keys/new.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import Layout from '@/layouts/layout.svelte';
  import { Button } from '@/lib/components/ui/button';
  import { Input } from '@/lib/components/ui/input';
  import { Label } from '@/lib/components/ui/label';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/lib/components/ui/card';

  let name = $state('');

  function createKey() {
    router.post('/api_keys', { name });
  }
</script>

<Layout title="Create API Key">
  <div class="container max-w-md py-8">
    <Card>
      <CardHeader>
        <CardTitle>Create API Key</CardTitle>
        <CardDescription>
          Create a new API key for CLI tools or automation.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form onsubmit|preventDefault={createKey} class="space-y-4">
          <div>
            <Label for="name">Key Name</Label>
            <Input
              id="name"
              bind:value={name}
              placeholder="e.g., Claude Code CLI"
              required
            />
            <p class="text-xs text-muted-foreground mt-1">
              A descriptive name to identify this key
            </p>
          </div>
          <Button type="submit" class="w-full">Create Key</Button>
        </form>
      </CardContent>
    </Card>
  </div>
</Layout>
```

### Show Token Page (one-time display)

**File:** `app/frontend/pages/api_keys/show.svelte`

```svelte
<script>
  import { Copy, Warning } from 'phosphor-svelte';
  import Layout from '@/layouts/layout.svelte';
  import { Button } from '@/lib/components/ui/button';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/lib/components/ui/card';
  import { Alert, AlertDescription } from '@/lib/components/ui/alert';

  let { api_key, raw_token, show_token_warning } = $props();
  let copied = $state(false);

  async function copyToken() {
    await navigator.clipboard.writeText(raw_token);
    copied = true;
    setTimeout(() => copied = false, 2000);
  }
</script>

<Layout title="API Key Created">
  <div class="container max-w-md py-8">
    <Card>
      <CardHeader>
        <CardTitle>API Key Created</CardTitle>
        <CardDescription>{api_key.name}</CardDescription>
      </CardHeader>
      <CardContent class="space-y-4">
        {#if show_token_warning}
          <Alert variant="warning">
            <Warning size={16} />
            <AlertDescription>
              Copy this key now. You won't be able to see it again.
            </AlertDescription>
          </Alert>
        {/if}

        <div class="relative">
          <code class="block p-3 bg-muted rounded text-sm break-all">
            {raw_token}
          </code>
          <Button
            variant="ghost"
            size="icon"
            class="absolute top-1 right-1"
            onclick={copyToken}
          >
            <Copy size={16} />
          </Button>
        </div>

        {#if copied}
          <p class="text-sm text-green-600">Copied to clipboard!</p>
        {/if}

        <Button href="/api_keys" variant="outline" class="w-full">
          Done
        </Button>
      </CardContent>
    </Card>
  </div>
</Layout>
```

### OAuth Approval Page

**File:** `app/frontend/pages/api_keys/approve.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { Key, Warning } from 'phosphor-svelte';
  import Layout from '@/layouts/layout.svelte';
  import { Button } from '@/lib/components/ui/button';
  import { Input } from '@/lib/components/ui/input';
  import { Label } from '@/lib/components/ui/label';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/lib/components/ui/card';

  let { request } = $props();
  let name = $state(request.client_name);

  function approve() {
    router.post(`/api_keys/approve/${request.request_token}`, { name });
  }

  function deny() {
    router.delete(`/api_keys/approve/${request.request_token}`);
  }
</script>

<Layout title="Approve API Key Request">
  <div class="container max-w-md py-8">
    <Card>
      <CardHeader>
        <Key size={32} class="mb-2" />
        <CardTitle>API Key Request</CardTitle>
        <CardDescription>
          A CLI tool is requesting access to your account
        </CardDescription>
      </CardHeader>
      <CardContent class="space-y-4">
        <div class="p-3 bg-muted rounded">
          <div class="text-sm text-muted-foreground">Requesting application:</div>
          <div class="font-medium">{request.client_name}</div>
        </div>

        <div>
          <Label for="name">Key Name</Label>
          <Input
            id="name"
            bind:value={name}
            placeholder="Name for this API key"
          />
        </div>

        <div class="flex gap-2">
          <Button onclick={approve} class="flex-1">
            Approve
          </Button>
          <Button onclick={deny} variant="outline" class="flex-1">
            Deny
          </Button>
        </div>

        <p class="text-xs text-muted-foreground text-center">
          This key will have full access to your conversations and whiteboards.
        </p>
      </CardContent>
    </Card>
  </div>
</Layout>
```

### Approved Confirmation Page

**File:** `app/frontend/pages/api_keys/approved.svelte`

```svelte
<script>
  import { CheckCircle } from 'phosphor-svelte';
  import Layout from '@/layouts/layout.svelte';
  import { Card, CardContent } from '@/lib/components/ui/card';

  let { message } = $props();
</script>

<Layout title="Key Approved">
  <div class="container max-w-md py-8">
    <Card>
      <CardContent class="py-8 text-center">
        <CheckCircle size={64} class="mx-auto mb-4 text-green-500" weight="fill" />
        <h2 class="text-xl font-bold mb-2">Success!</h2>
        <p class="text-muted-foreground">{message}</p>
      </CardContent>
    </Card>
  </div>
</Layout>
```

---

## 9. CLI Authentication Flow

The CLI authentication works as follows:

1. **CLI initiates request:**
   ```bash
   curl -X POST https://app.example.com/api/v1/key_requests \
     -H "Content-Type: application/json" \
     -d '{"client_name": "Claude Code"}'
   ```

   Response:
   ```json
   {
     "request_token": "abc123...",
     "approval_url": "https://app.example.com/api_keys/approve/abc123...",
     "poll_url": "https://app.example.com/api/v1/key_requests/abc123...",
     "expires_at": "2026-01-15T12:10:00Z"
   }
   ```

2. **CLI opens browser to approval_url** (or prints URL for user to visit)

3. **User approves in browser** (must be logged in)

4. **CLI polls for status:**
   ```bash
   curl https://app.example.com/api/v1/key_requests/abc123...
   ```

   While pending:
   ```json
   { "status": "pending", "client_name": "Claude Code" }
   ```

   After approval:
   ```json
   {
     "status": "approved",
     "client_name": "Claude Code",
     "api_key": "hx_...",
     "user_email": "user@example.com"
   }
   ```

5. **CLI stores the API key** for future use

---

## 10. Implementation Checklist

### Database
- [ ] Generate migration for api_keys table
- [ ] Generate migration for api_key_requests table
- [ ] Generate migration to add summary to chats
- [ ] Run migrations

### Models
- [ ] Create `app/models/api_key.rb`
- [ ] Create `app/models/api_key_request.rb`
- [ ] Add `has_many :api_keys` to User model
- [ ] Add summary methods to Chat model
- [ ] Update Chat json_attributes to include summary

### Prompts
- [ ] Create `app/prompts/generate_summary_prompt.rb`
- [ ] Create `app/prompts/generate_summary/system.prompt.erb`
- [ ] Create `app/prompts/generate_summary/user.prompt.erb`

### Controllers
- [ ] Create `app/controllers/concerns/api_authentication.rb`
- [ ] Create `app/controllers/api/v1/base_controller.rb`
- [ ] Create `app/controllers/api/v1/conversations_controller.rb`
- [ ] Create `app/controllers/api/v1/whiteboards_controller.rb`
- [ ] Create `app/controllers/api/v1/key_requests_controller.rb`
- [ ] Create `app/controllers/api_keys_controller.rb`

### Routes
- [ ] Add API routes to `config/routes.rb`
- [ ] Add API key management routes

### Frontend
- [ ] Create `app/frontend/pages/api_keys/index.svelte`
- [ ] Create `app/frontend/pages/api_keys/new.svelte`
- [ ] Create `app/frontend/pages/api_keys/show.svelte`
- [ ] Create `app/frontend/pages/api_keys/approve.svelte`
- [ ] Create `app/frontend/pages/api_keys/approved.svelte`
- [ ] Run `bin/rails js_from_routes:generate`

### Testing
- [ ] ApiKey model tests (generation, authentication)
- [ ] ApiKeyRequest model tests (flow, expiry)
- [ ] Chat summary generation tests
- [ ] API controller tests
- [ ] Authentication concern tests

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
    assert_equal "hx_", key.token_prefix[0, 3]
  end

  test "authenticates valid token" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    raw_token = key.raw_token

    authenticated = ApiKey.authenticate(raw_token)
    assert_equal key, authenticated
  end

  test "rejects invalid token" do
    assert_nil ApiKey.authenticate("invalid_token")
    assert_nil ApiKey.authenticate(nil)
    assert_nil ApiKey.authenticate("")
  end

  test "raw_token only available once" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    first_access = key.raw_token

    # Simulate reload
    key = ApiKey.find(key.id)
    assert_nil key.raw_token
  end

  test "touches usage on authentication" do
    key = ApiKey.generate_for(@user, name: "Test Key")
    raw_token = key.raw_token

    assert_nil key.last_used_at
    key.touch_usage!("192.168.1.1")

    key.reload
    assert_not_nil key.last_used_at
    assert_equal "192.168.1.1", key.last_used_ip
  end
end
```

### API Controller Tests

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
        @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Test Chat")
        @chat.messages.create!(content: "Hello", role: "user", user: @user)
      end

      test "lists conversations with auth" do
        get api_v1_conversations_url, headers: auth_headers

        assert_response :success
        json = JSON.parse(response.body)
        assert_includes json["conversations"].map { |c| c["id"] }, @chat.to_param
      end

      test "returns unauthorized without token" do
        get api_v1_conversations_url

        assert_response :unauthorized
      end

      test "shows conversation transcript" do
        get api_v1_conversation_url(@chat.to_param), headers: auth_headers

        assert_response :success
        json = JSON.parse(response.body)
        assert_equal @chat.title, json["conversation"]["title"]
        assert_not_empty json["conversation"]["transcript"]
      end

      test "creates message and triggers AI in 1-1 chat" do
        assert_enqueued_with(job: AiResponseJob) do
          post create_message_api_v1_conversation_url(@chat.to_param),
               params: { content: "New message" },
               headers: auth_headers
        end

        assert_response :created
        json = JSON.parse(response.body)
        assert json["ai_response_triggered"]
      end

      test "creates message without AI trigger in group chat" do
        @chat.update!(manual_responses: true)
        agent = @account.agents.create!(name: "Test Agent")
        @chat.agents << agent

        assert_no_enqueued_jobs(only: AiResponseJob) do
          post create_message_api_v1_conversation_url(@chat.to_param),
               params: { content: "New message" },
               headers: auth_headers
        end

        assert_response :created
        json = JSON.parse(response.body)
        assert_not json["ai_response_triggered"]
      end

      private

      def auth_headers
        { "Authorization" => "Bearer #{@token}" }
      end
    end
  end
end
```

---

## 12. API Documentation (for AI clients)

### Authentication

All API requests require a Bearer token in the Authorization header:

```
Authorization: Bearer hx_your_api_key_here
```

### Endpoints

#### List Conversations
```
GET /api/v1/conversations
```

Response:
```json
{
  "conversations": [
    {
      "id": "abc123",
      "title": "Project Planning",
      "summary": "Discussion about Q1 roadmap...",
      "model": "GPT-5",
      "message_count": 24,
      "participants": [...],
      "whiteboard": { "id": "xyz", "name": "Roadmap", "summary": "..." },
      "updated_at": "2026-01-15T10:30:00Z"
    }
  ]
}
```

#### Get Conversation Transcript
```
GET /api/v1/conversations/:id
```

Response includes full transcript without images, thinking traces, or tool calls.

#### Post Message
```
POST /api/v1/conversations/:id/create_message
Content-Type: application/json

{ "content": "Your message here" }
```

AI response is automatically triggered in 1-1 conversations.

#### List Whiteboards
```
GET /api/v1/whiteboards
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
  "content": "New content here",
  "expected_revision": 5
}
```

---

## 13. Security Considerations

- **Token hashing**: API keys are stored as bcrypt hashes, never plaintext
- **One-time token display**: Raw tokens only shown once at creation
- **Prefix indexing**: Quick lookup without exposing full token
- **Request expiry**: OAuth-style requests expire in 10 minutes
- **User scoping**: All data access scoped through authenticated user's account
- **IP tracking**: Last used IP recorded for audit purposes
- **No cross-account access**: Personal account only (simplifies security model)

---

## 14. Code Summary

| Component | Lines | File |
|-----------|-------|------|
| Migrations (3) | 45 | `db/migrate/*` |
| ApiKey model | 60 | `app/models/api_key.rb` |
| ApiKeyRequest model | 50 | `app/models/api_key_request.rb` |
| Chat model additions | 35 | `app/models/chat.rb` |
| User model additions | 3 | `app/models/user.rb` |
| GenerateSummaryPrompt | 45 | `app/prompts/generate_summary_prompt.rb` |
| Prompt templates | 20 | `app/prompts/generate_summary/*` |
| ApiAuthentication concern | 30 | `app/controllers/concerns/api_authentication.rb` |
| API controllers (4) | 150 | `app/controllers/api/v1/*` |
| ApiKeysController | 80 | `app/controllers/api_keys_controller.rb` |
| Routes | 20 | `config/routes.rb` |
| Frontend pages (5) | 200 | `app/frontend/pages/api_keys/*` |
| Tests | ~150 | Various test files |
| **Total** | **~900** | |

---

## 15. Future Considerations (Out of Scope)

- Rate limiting for API endpoints
- Scoped API keys (read-only, specific resources)
- API key expiration dates
- Webhook callbacks for AI response completion
- Batch message retrieval
- Team account access (currently personal account only)
- OpenAPI/Swagger documentation generation
