# Telegram Notifications

## Executive Summary

Add one-way Telegram notifications so agents can reach users outside the web app. Each agent gets its own Telegram bot (created via BotFather). Users send `/start` to a bot to register their `chat_id`, after which the bot can notify them when the agent initiates a conversation or posts a spontaneous reply. No two-way messaging -- just notifications with a message preview and a link back to the web app.

## Architecture Overview

The design follows the existing pattern: logic in models, thin controllers, Solid Queue jobs for async work. No service objects. No gems -- the Telegram Bot API is simple enough that raw HTTP calls via `Net::HTTP` (already available in stdlib) are sufficient.

Key entities:
- **Agent** gains `telegram_bot_token` (encrypted) and `telegram_bot_username`
- **New model: `TelegramSubscription`** links a user to an agent's bot via `chat_id`
- **New controller: `TelegramWebhooksController`** receives `/start` commands
- **New job: `TelegramNotificationJob`** sends the actual message
- Notifications are triggered from two existing points: `Chat.initiate_by_agent!` and `ManualAgentResponseJob`

```
User sends /start to @AgentBot on Telegram
  -> Telegram POSTs to /telegram/webhook/:token
  -> TelegramWebhooksController finds agent by token, enqueues job
  -> ProcessTelegramUpdateJob stores TelegramSubscription

Agent initiates conversation or posts spontaneous reply
  -> after_create callback / job fires TelegramNotificationJob
  -> TelegramNotificationJob sends message via Telegram API
```

## Implementation Plan

### 1. Database Migrations

- [ ] **Add Telegram fields to agents**

```ruby
class AddTelegramToAgents < ActiveRecord::Migration[8.0]
  def change
    add_column :agents, :telegram_bot_token, :string
    add_column :agents, :telegram_bot_username, :string
  end
end
```

- [ ] **Create telegram_subscriptions table**

```ruby
class CreateTelegramSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :telegram_subscriptions do |t|
      t.references :agent, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.bigint :telegram_chat_id, null: false
      t.string :telegram_username
      t.string :telegram_first_name
      t.boolean :blocked, default: false
      t.timestamps
    end

    add_index :telegram_subscriptions, [:agent_id, :user_id], unique: true
    add_index :telegram_subscriptions, [:agent_id, :telegram_chat_id], unique: true
  end
end
```

### 2. Model Changes

- [ ] **Agent model additions** (`app/models/agent.rb`)

```ruby
has_many :telegram_subscriptions, dependent: :destroy

encrypts :telegram_bot_token

validates :telegram_bot_username, format: { with: /\A[a-zA-Z0-9_]+\z/ }, allow_blank: true

def telegram_configured?
  telegram_bot_token.present? && telegram_bot_username.present?
end

def telegram_api_url(method)
  "https://api.telegram.org/bot#{telegram_bot_token}/#{method}"
end

def telegram_send_message(chat_id, text, options = {})
  uri = URI(telegram_api_url("sendMessage"))
  body = { chat_id: chat_id, text: text, parse_mode: "HTML" }.merge(options)

  response = Net::HTTP.post(uri, body.to_json, "Content-Type" => "application/json")
  result = JSON.parse(response.body)

  unless result["ok"]
    raise TelegramError, result["description"] if response.code.to_i == 403
    Rails.logger.error "[Telegram] sendMessage failed: #{result['description']}"
  end

  result
end

def set_telegram_webhook!
  return unless telegram_configured?

  webhook_url = "#{Rails.application.credentials.dig(:app, :url)}/telegram/webhook/#{webhook_token}"
  uri = URI(telegram_api_url("setWebhook"))
  body = {
    url: webhook_url,
    allowed_updates: ["message"],
    secret_token: telegram_webhook_secret
  }

  Net::HTTP.post(uri, body.to_json, "Content-Type" => "application/json")
end

def delete_telegram_webhook!
  return unless telegram_bot_token.present?
  uri = URI(telegram_api_url("deleteWebhook"))
  Net::HTTP.post(uri, { drop_pending_updates: true }.to_json, "Content-Type" => "application/json")
end

def webhook_token
  Digest::SHA256.hexdigest("#{id}-#{telegram_bot_token}")[0..31]
end

def telegram_webhook_secret
  Digest::SHA256.hexdigest("#{telegram_bot_token}-webhook-secret")[0..31]
end

def notify_subscribers!(message_record, chat)
  return unless telegram_configured?

  account.users.each do |user|
    subscription = telegram_subscriptions.find_by(user: user, blocked: false)
    next unless subscription

    TelegramNotificationJob.perform_later(subscription, message_record, chat)
  end
end

class TelegramError < StandardError; end
```

Add `telegram_bot_token` and `telegram_bot_username` to `json_attributes` so the edit page can display them.

- [ ] **New model: TelegramSubscription** (`app/models/telegram_subscription.rb`)

```ruby
class TelegramSubscription < ApplicationRecord
  belongs_to :agent
  belongs_to :user

  scope :active, -> { where(blocked: false) }

  def mark_blocked!
    update!(blocked: true)
  end
end
```

- [ ] **Chat model: trigger notifications on agent initiation**

In `Chat.initiate_by_agent!`, after creating the message, add:

```ruby
agent.notify_subscribers!(chat.messages.last, chat)
```

### 3. Controller Changes

- [ ] **AgentsController: permit new params**

Add to `agent_params`:
```ruby
:telegram_bot_token, :telegram_bot_username
```

Add `telegram_bot_token` and `telegram_bot_username` to the json_attributes in Agent so they're available in the edit page props.

Add a callback in `update` to set/update webhook when token changes:

```ruby
def update
  token_changed = @agent.telegram_bot_token != agent_params[:telegram_bot_token]

  if @agent.update(agent_params)
    @agent.set_telegram_webhook! if token_changed && @agent.telegram_configured?
    audit("update_agent", @agent, **agent_params.to_h)
    redirect_to account_agents_path(current_account), notice: "Agent updated"
  else
    redirect_to edit_account_agent_path(current_account, @agent),
                inertia: { errors: @agent.errors.to_hash }
  end
end
```

- [ ] **New controller: TelegramWebhooksController** (`app/controllers/telegram_webhooks_controller.rb`)

```ruby
class TelegramWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :require_authentication

  def receive
    agent = find_agent_by_webhook_token
    return head(:not_found) unless agent
    return head(:unauthorized) unless valid_secret?(agent)

    update = JSON.parse(request.body.read)
    ProcessTelegramUpdateJob.perform_later(agent.id, update)

    head :ok
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def find_agent_by_webhook_token
    token = params[:token]
    Agent.find_each.detect { |a| a.telegram_configured? && a.webhook_token == token }
  end

  def valid_secret?(agent)
    provided = request.headers["X-Telegram-Bot-Api-Secret-Token"].to_s
    expected = agent.telegram_webhook_secret
    ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end
end
```

**Note on `find_agent_by_webhook_token`**: The naive `find_each` approach works for small numbers of agents but will need optimization if scale grows. A better approach is to store a plaintext `webhook_token` column (it's derived from the agent id + bot token, not secret itself) and look up directly. This is a refinement for later.

### 4. Routes

- [ ] **Add webhook route**

```ruby
post "telegram/webhook/:token", to: "telegram_webhooks#receive", as: :telegram_webhook
```

### 5. Jobs

- [ ] **ProcessTelegramUpdateJob** (`app/jobs/process_telegram_update_job.rb`)

```ruby
class ProcessTelegramUpdateJob < ApplicationJob
  queue_as :default

  def perform(agent_id, update)
    agent = Agent.find(agent_id)
    message = update.dig("message")
    return unless message

    text = message.dig("text")
    return unless text&.start_with?("/start")

    chat_id = message.dig("chat", "id")
    from = message["from"]
    telegram_username = from["username"]

    user = match_user(agent, telegram_username, text)
    return send_unknown_user_message(agent, chat_id) unless user

    subscription = agent.telegram_subscriptions.find_or_initialize_by(user: user)
    subscription.update!(
      telegram_chat_id: chat_id,
      telegram_username: telegram_username,
      telegram_first_name: from["first_name"],
      blocked: false
    )

    agent.telegram_send_message(
      chat_id,
      "Connected! You'll receive notifications from <b>#{ERB::Util.html_escape(agent.name)}</b> here.",
      parse_mode: "HTML"
    )
  end

  private

  def match_user(agent, telegram_username, text)
    deep_link_param = text.split(" ", 2)[1]

    if deep_link_param.present?
      user_id = decode_deep_link(deep_link_param)
      user = agent.account.users.find_by(id: user_id)
      return user if user
    end

    nil
  end

  def decode_deep_link(param)
    Base64.urlsafe_decode64(param)
  rescue ArgumentError
    nil
  end

  def send_unknown_user_message(agent, chat_id)
    agent.telegram_send_message(
      chat_id,
      "I couldn't identify your account. Please use the registration link from the app.",
      parse_mode: "HTML"
    )
  end
end
```

- [ ] **TelegramNotificationJob** (`app/jobs/telegram_notification_job.rb`)

```ruby
class TelegramNotificationJob < ApplicationJob
  queue_as :default

  retry_on Agent::TelegramError, wait: 30.seconds, attempts: 2

  def perform(subscription, message, chat)
    return if subscription.blocked?

    agent = subscription.agent
    return unless agent.telegram_configured?

    preview = message.content.to_s.truncate(300)
    chat_url = "#{Rails.application.credentials.dig(:app, :url)}/accounts/#{chat.account_id}/chats/#{chat.to_param}"

    text = <<~HTML.strip
      <b>#{ERB::Util.html_escape(agent.name)}</b> in "#{ERB::Util.html_escape(chat.title_or_default)}"

      #{ERB::Util.html_escape(preview)}
    HTML

    agent.telegram_send_message(
      subscription.telegram_chat_id,
      text,
      parse_mode: "HTML",
      reply_markup: {
        inline_keyboard: [[
          { text: "Open Conversation", url: chat_url }
        ]]
      }
    )
  rescue Agent::TelegramError => e
    if e.message.include?("blocked") || e.message.include?("chat not found")
      subscription.mark_blocked!
    else
      raise
    end
  end
end
```

- [ ] **Trigger from ManualAgentResponseJob**

In `ManualAgentResponseJob#perform`, after `finalize_message!` completes (in the `on_end_message` callback), add notification:

```ruby
llm.on_end_message do |msg|
  debug_info "Response complete - #{msg.content&.length || 0} chars"
  finalize_message!(msg)
  @agent.notify_subscribers!(@ai_message, @chat) if @ai_message&.persisted?
end
```

- [ ] **Trigger from Chat.initiate_by_agent!**

After the message is created in the transaction:

```ruby
def self.initiate_by_agent!(agent, topic:, message:, reason: nil)
  transaction do
    # ... existing code ...
    chat.messages.create!(role: "assistant", agent: agent, content: message)
    chat
  end.tap do |chat|
    agent.notify_subscribers!(chat.messages.last, chat)
  end
end
```

### 6. Frontend Changes

- [ ] **Agent edit page: add Telegram configuration card**

Add a new Card section to `app/frontend/pages/agents/edit.svelte` between the Tools card and the Memory card:

```svelte
<Card>
  <CardHeader>
    <CardTitle>Telegram Notifications</CardTitle>
    <CardDescription>
      Connect a Telegram bot to send notifications when this agent initiates conversations or replies.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <div class="space-y-2">
      <Label for="telegram_bot_username">Bot Username</Label>
      <Input
        id="telegram_bot_username"
        type="text"
        bind:value={$form.agent.telegram_bot_username}
        placeholder="e.g., my_agent_bot" />
      <p class="text-xs text-muted-foreground">
        Create a bot via <a href="https://t.me/botfather" target="_blank" class="underline">@BotFather</a> on Telegram, then paste the username here.
      </p>
    </div>

    <div class="space-y-2">
      <Label for="telegram_bot_token">Bot Token</Label>
      <Input
        id="telegram_bot_token"
        type="password"
        bind:value={$form.agent.telegram_bot_token}
        placeholder="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11" />
      <p class="text-xs text-muted-foreground">
        The API token provided by BotFather. This is stored encrypted.
      </p>
    </div>

    {#if agent.telegram_bot_username && agent.telegram_bot_token}
      <div class="p-3 rounded-lg bg-muted/50 space-y-2">
        <p class="text-sm font-medium">Registration Link</p>
        <p class="text-xs text-muted-foreground">
          Share this link with users so they can receive notifications from this agent:
        </p>
        <code class="text-xs block p-2 bg-background rounded border break-all">
          https://t.me/{agent.telegram_bot_username}?start={registrationParam}
        </code>
      </div>
    {/if}
  </CardContent>
</Card>
```

Add to the form initialization:
```javascript
telegram_bot_token: agent.telegram_bot_token || '',
telegram_bot_username: agent.telegram_bot_username || '',
```

Add a derived value for the deep link parameter:
```javascript
import { page } from '@inertiajs/svelte';

let registrationParam = $derived(
  btoa(String($page.props.auth?.user?.id || ''))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
);
```

- [ ] **Add telegram fields to agent_params and json_attributes**

In `Agent` model, add to `json_attributes`:
```ruby
json_attributes :name, ..., :telegram_bot_username, :telegram_configured?
```

Note: Do NOT include `telegram_bot_token` in json_attributes directly. Instead, expose a masked version or a boolean `telegram_configured?` for display purposes. The edit form should receive the token only on the edit page (pass it explicitly in the controller).

Actually, since the token is encrypted and needs to be editable, pass it in the edit controller props but mask it in the agent list. In the edit action:

```ruby
def edit
  render inertia: "agents/edit", props: {
    agent: @agent.as_json.merge(
      "telegram_bot_token" => @agent.telegram_bot_token
    ),
    # ... rest unchanged
  }
end
```

### 7. Webhook Setup Flow

- [ ] **Set webhook when bot token is saved**

After the agent is updated with a new token, call `set_telegram_webhook!`. This sets the webhook URL to `https://app-domain/telegram/webhook/:webhook_token`.

- [ ] **Delete webhook when token is cleared**

If the token is removed, call `delete_telegram_webhook!` before clearing.

### 8. Security Considerations

- Bot tokens are encrypted at rest via `encrypts :telegram_bot_token`
- Webhook endpoints verify the `X-Telegram-Bot-Api-Secret-Token` header
- Webhook tokens are derived hashes, not guessable
- Deep link params encode user IDs (not secret, but sufficient for matching)
- The webhook controller skips CSRF and authentication (it's called by Telegram)

### 9. Testing Strategy

- [ ] **Model tests for Agent Telegram methods**
  - `telegram_configured?` returns true/false correctly
  - `webhook_token` is deterministic
  - `notify_subscribers!` enqueues jobs for active subscriptions only

- [ ] **Model tests for TelegramSubscription**
  - Uniqueness validations
  - `mark_blocked!` sets blocked flag

- [ ] **Controller test for TelegramWebhooksController**
  - Returns 404 for unknown webhook tokens
  - Returns 401 for invalid secret tokens
  - Returns 200 and enqueues job for valid requests
  - Returns 400 for malformed JSON

- [ ] **Job tests for ProcessTelegramUpdateJob**
  - Creates subscription on `/start` with valid deep link
  - Sends error message for unknown users
  - Updates existing subscription (unblocks)

- [ ] **Job tests for TelegramNotificationJob**
  - Skips blocked subscriptions
  - Marks subscription blocked on 403 response
  - Sends correctly formatted HTML message with inline keyboard

- [ ] **Integration tests**
  - Agent initiation triggers notification
  - ManualAgentResponseJob triggers notification after response

### 10. Edge Cases

- **User blocks the bot**: 403 response marks subscription as blocked
- **Bot token is invalid**: Webhook setup fails, logged but not blocking
- **Multiple users per account**: Each user registers independently; all active subscribers get notified
- **Agent has no bot configured**: `telegram_configured?` short-circuits, no errors
- **Rate limiting**: Telegram allows ~30 msg/sec; with Solid Queue serializing jobs this is unlikely to be an issue at current scale
- **Token rotation**: Updating the token sets a new webhook and invalidates the old one

### 11. Future Considerations (Out of Scope)

- Two-way messaging via Telegram
- Per-user notification preferences (mute specific agents)
- Notification batching/digest mode
- Group chat notifications on Telegram
- WhatsApp notifications (separate feature)
