# Telegram Notifications (v2)

## Executive Summary

One-way Telegram notifications so agents can reach users outside the web app. Each agent gets its own Telegram bot (via BotFather). Users send `/start` to register, then receive notifications when the agent initiates or spontaneously replies. No two-way messaging -- just notifications with a preview and a link back.

This revision incorporates all feedback from DHH review: Telegram logic extracted to a concern, O(1) webhook routing via stored token, signed deep links, model callbacks for webhook management, and consistent error handling.

## Architecture Overview

No gems, no service objects. Raw `Net::HTTP` for Telegram API calls. Logic in models (via concern), thin controllers, Solid Queue jobs for async work.

Key entities:
- **`TelegramNotifiable` concern** on Agent -- all Telegram logic lives here
- **`TelegramSubscription` model** -- links a user to an agent's bot via `chat_id`
- **`TelegramWebhooksController`** -- receives updates from Telegram
- **`ProcessTelegramUpdateJob`** -- handles `/start` registration
- **`TelegramNotificationJob`** -- sends the actual notification

```
User sends /start to @AgentBot on Telegram
  -> Telegram POSTs to /telegram/webhook/:token
  -> TelegramWebhooksController finds agent by telegram_webhook_token column (O(1))
  -> ProcessTelegramUpdateJob creates TelegramSubscription

Agent initiates or spontaneously replies
  -> notify_subscribers! enqueues TelegramNotificationJob per active subscription
  -> Job sends HTML message with inline keyboard link back to web app
```

## Implementation Plan

### 1. Database Migrations

- [ ] **Add Telegram fields to agents**

```ruby
class AddTelegramToAgents < ActiveRecord::Migration[8.0]
  def change
    add_column :agents, :telegram_bot_token, :string
    add_column :agents, :telegram_bot_username, :string
    add_column :agents, :telegram_webhook_token, :string

    add_index :agents, :telegram_webhook_token, unique: true
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
      t.boolean :blocked, default: false
      t.timestamps
    end

    add_index :telegram_subscriptions, [:agent_id, :user_id], unique: true
    add_index :telegram_subscriptions, [:agent_id, :telegram_chat_id], unique: true
  end
end
```

No `telegram_username` or `telegram_first_name` columns -- they are never referenced in the notification flow. If needed for debugging later, log them.

### 2. TelegramNotifiable Concern

- [ ] **Create concern** (`app/models/concerns/telegram_notifiable.rb`)

```ruby
module TelegramNotifiable
  extend ActiveSupport::Concern

  class TelegramError < StandardError; end

  included do
    has_many :telegram_subscriptions, dependent: :destroy

    encrypts :telegram_bot_token

    validates :telegram_bot_username, format: { with: /\A[a-zA-Z0-9_]+\z/ }, allow_blank: true

    before_save :set_telegram_webhook_token, if: :telegram_bot_token_changed?
    after_update_commit :manage_telegram_webhook, if: :saved_change_to_telegram_bot_token?
  end

  def telegram_configured?
    telegram_bot_token.present? && telegram_bot_username.present?
  end

  def telegram_send_message(chat_id, text, **options)
    body = { chat_id: chat_id, text: text, parse_mode: "HTML" }.merge(options)
    result = telegram_api_request("sendMessage", body)

    unless result["ok"]
      raise TelegramError, result["description"]
    end

    result
  end

  def set_telegram_webhook!
    return unless telegram_configured?

    webhook_url = "#{Rails.application.credentials.dig(:app, :url)}/telegram/webhook/#{telegram_webhook_token}"
    telegram_api_request("setWebhook", {
      url: webhook_url,
      allowed_updates: ["message"],
      secret_token: telegram_webhook_secret
    })
  end

  def delete_telegram_webhook!
    return unless telegram_bot_token.present?
    telegram_api_request("deleteWebhook", { drop_pending_updates: true })
  end

  def telegram_webhook_secret
    Digest::SHA256.hexdigest("#{telegram_bot_token}-webhook-secret")[0..31]
  end

  def notify_subscribers!(message, chat)
    return unless telegram_configured?

    telegram_subscriptions.active.each do |subscription|
      TelegramNotificationJob.perform_later(subscription, message, chat)
    end
  end

  def telegram_deep_link_for(user)
    token = Rails.application.message_verifier(:telegram_deep_link).generate(user.id, expires_in: 7.days)
    "https://t.me/#{telegram_bot_username}?start=#{token}"
  end

  private

  def telegram_api_request(method, body)
    uri = URI("https://api.telegram.org/bot#{telegram_bot_token}/#{method}")
    response = Net::HTTP.post(uri, body.to_json, "Content-Type" => "application/json")
    JSON.parse(response.body)
  end

  def set_telegram_webhook_token
    if telegram_bot_token.present?
      self.telegram_webhook_token = Digest::SHA256.hexdigest("#{id}-#{telegram_bot_token}")[0..31]
    else
      self.telegram_webhook_token = nil
    end
  end

  def manage_telegram_webhook
    telegram_configured? ? set_telegram_webhook! : delete_telegram_webhook!
  end
end
```

- [ ] **Include in Agent model** (`app/models/agent.rb`)

Add `include TelegramNotifiable` to the top of the class, alongside existing concerns.

Add `telegram_bot_username` and `telegram_configured?` to `json_attributes`.

### 3. TelegramSubscription Model

- [ ] **Create model** (`app/models/telegram_subscription.rb`)

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

### 4. Controller

- [ ] **TelegramWebhooksController** (`app/controllers/telegram_webhooks_controller.rb`)

```ruby
class TelegramWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :require_authentication

  def receive
    agent = Agent.find_by(telegram_webhook_token: params[:token])
    return head(:not_found) unless agent

    unless valid_secret?(agent)
      return head(:unauthorized)
    end

    update = JSON.parse(request.body.read)
    ProcessTelegramUpdateJob.perform_later(agent.id, update)

    head :ok
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def valid_secret?(agent)
    provided = request.headers["X-Telegram-Bot-Api-Secret-Token"].to_s
    ActiveSupport::SecurityUtils.secure_compare(provided, agent.telegram_webhook_secret)
  end
end
```

- [ ] **AgentsController: permit new params**

Add `:telegram_bot_token, :telegram_bot_username` to `agent_params`. No webhook logic in the controller -- the `after_update_commit` callback handles it.

### 5. Routes

- [ ] **Add webhook route**

```ruby
post "telegram/webhook/:token", to: "telegram_webhooks#receive", as: :telegram_webhook
```

### 6. Jobs

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
    deep_link_param = text.split(" ", 2)[1]

    user = verify_deep_link(agent, deep_link_param)
    return send_unknown_user_message(agent, chat_id) unless user

    subscription = agent.telegram_subscriptions.find_or_initialize_by(user: user)
    subscription.update!(telegram_chat_id: chat_id, blocked: false)

    agent.telegram_send_message(
      chat_id,
      "Connected! You'll receive notifications from <b>#{ERB::Util.html_escape(agent.name)}</b> here."
    )
  end

  private

  def verify_deep_link(agent, param)
    return nil unless param.present?

    user_id = Rails.application.message_verifier(:telegram_deep_link).verified(param)
    return nil unless user_id

    agent.account.users.find_by(id: user_id)
  end

  def send_unknown_user_message(agent, chat_id)
    agent.telegram_send_message(
      chat_id,
      "I couldn't identify your account. Please use the registration link from the app."
    )
  end
end
```

- [ ] **TelegramNotificationJob** (`app/jobs/telegram_notification_job.rb`)

```ruby
class TelegramNotificationJob < ApplicationJob
  queue_as :default

  retry_on TelegramNotifiable::TelegramError, wait: 30.seconds, attempts: 2

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
      reply_markup: {
        inline_keyboard: [[{ text: "Open Conversation", url: chat_url }]]
      }
    )
  rescue TelegramNotifiable::TelegramError => e
    if e.message.include?("blocked") || e.message.include?("chat not found")
      subscription.mark_blocked!
    else
      raise
    end
  end
end
```

### 7. Trigger Points

- [ ] **Chat.initiate_by_agent!** -- after the transaction completes:

```ruby
def self.initiate_by_agent!(agent, topic:, message:, reason: nil)
  transaction do
    # ... existing code ...
  end.tap do |chat|
    agent.notify_subscribers!(chat.messages.last, chat)
  end
end
```

- [ ] **ManualAgentResponseJob** -- after `finalize_message!`:

```ruby
llm.on_end_message do |msg|
  debug_info "Response complete - #{msg.content&.length || 0} chars"
  finalize_message!(msg)
  @agent.notify_subscribers!(@ai_message, @chat) if @ai_message&.persisted?
end
```

### 8. Frontend Changes

- [ ] **Agent edit page: add Telegram configuration card**

Add a new Card section to `app/frontend/pages/agents/edit.svelte`:

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
        The API token provided by BotFather. Stored encrypted.
      </p>
    </div>

    {#if agent.telegram_configured}
      <div class="p-3 rounded-lg bg-muted/50 space-y-2">
        <p class="text-sm font-medium">Registration Link</p>
        <p class="text-xs text-muted-foreground">
          Share this link with users so they can receive notifications:
        </p>
        <code class="text-xs block p-2 bg-background rounded border break-all">
          {telegramDeepLink}
        </code>
      </div>
    {/if}
  </CardContent>
</Card>
```

The `telegramDeepLink` is passed as a prop from the controller (generated server-side using `message_verifier`), not computed client-side. This ensures the signed token is generated properly.

- [ ] **AgentsController#edit: pass telegram props**

```ruby
def edit
  render inertia: "agents/edit", props: {
    agent: @agent.as_json.merge(
      "telegram_bot_token" => @agent.telegram_bot_token
    ),
    telegram_deep_link: @agent.telegram_configured? ? @agent.telegram_deep_link_for(current_user) : nil,
    # ... rest unchanged
  }
end
```

### 9. Security

- Bot tokens encrypted at rest via `encrypts :telegram_bot_token`
- Webhook endpoints verify `X-Telegram-Bot-Api-Secret-Token` header with `secure_compare`
- `telegram_webhook_token` stored as column for O(1) lookup -- derived from agent ID + bot token, not secret
- Deep link tokens use `Rails.application.message_verifier` with 7-day expiry -- signed, tamper-proof, time-limited
- Webhook controller skips CSRF and authentication (called by Telegram)

### 10. Testing Strategy

- [ ] **Concern tests** (`test/models/concerns/telegram_notifiable_test.rb`)
  - `telegram_configured?` returns true/false correctly
  - `set_telegram_webhook_token` callback populates column on save
  - `notify_subscribers!` enqueues jobs for active subscriptions only, skips blocked
  - `telegram_send_message` raises `TelegramError` on non-ok response

- [ ] **TelegramSubscription model tests**
  - Uniqueness on `[agent_id, user_id]`
  - `mark_blocked!` sets blocked flag
  - `.active` scope excludes blocked

- [ ] **TelegramWebhooksController tests**
  - 404 for unknown webhook tokens
  - 401 for invalid secret tokens
  - 200 and enqueues job for valid requests
  - 400 for malformed JSON

- [ ] **ProcessTelegramUpdateJob tests**
  - Creates subscription on `/start` with valid signed deep link
  - Rejects expired deep link tokens
  - Rejects tampered deep link tokens
  - Sends error message for unknown/unmatched users
  - Updates existing subscription (unblocks, updates chat_id)

- [ ] **TelegramNotificationJob tests**
  - Skips blocked subscriptions
  - Marks subscription blocked on "blocked"/"chat not found" errors
  - Re-raises other TelegramErrors for retry
  - Sends correctly formatted HTML with inline keyboard

- [ ] **Integration tests**
  - Agent initiation triggers notification
  - ManualAgentResponseJob triggers notification after response

### 11. Edge Cases

- **User blocks the bot**: API returns error with "blocked", job catches it and marks subscription blocked
- **User unblocks and sends /start again**: Subscription is found by `find_or_initialize_by(user:)`, `blocked` set to `false`
- **Bot token invalid**: `manage_telegram_webhook` callback fires `set_telegram_webhook!` which fails -- logged but not blocking (it is a POST that returns `{"ok": false}`)
- **Deep link expired**: `message_verifier.verified` returns `nil`, user gets "couldn't identify" message
- **Multiple users per account**: Each registers independently via their own deep link
- **Token rotation**: `before_save` recomputes `telegram_webhook_token`, `after_update_commit` sets new webhook with Telegram
- **Token cleared**: `telegram_webhook_token` set to nil, `manage_telegram_webhook` calls `delete_telegram_webhook!`
- **Rate limiting**: Telegram allows ~30 msg/sec; Solid Queue serializing jobs makes this unlikely at current scale

### 12. Future Considerations (Out of Scope)

- Two-way messaging via Telegram
- Per-user notification preferences
- Notification batching/digest mode
- WhatsApp notifications (separate feature)
