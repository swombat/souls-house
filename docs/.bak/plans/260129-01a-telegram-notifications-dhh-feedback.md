# DHH Review: Telegram Notifications Spec

## Overall Assessment

This spec is solid work. It follows the project's established patterns -- logic in models, thin controllers, jobs for async work, no service objects. The decision to skip a Telegram gem in favor of raw `Net::HTTP` is the right call for this scope. But there are several areas where the design drifts into over-engineering or makes choices that will cause pain down the road.

## Critical Issues

### 1. The Agent model is becoming a Telegram client

The spec dumps `telegram_api_url`, `telegram_send_message`, `set_telegram_webhook!`, `delete_telegram_webhook!`, `webhook_token`, `telegram_webhook_secret`, and `notify_subscribers!` directly into `Agent`. That is seven methods plus an error class, all for a single notification channel. The Agent model (`/Users/danieltenner/dev/helix_kit/app/models/agent.rb`) is already 240 lines with initiation logic. This would push it past 300 and muddy its responsibility.

This is exactly what concerns are for. Extract a `Telegram::Notifiable` concern (or simply `TelegramNotifiable`). The Agent model stays clean, the Telegram logic is cohesive and self-contained, and you can test it in isolation.

```ruby
# app/models/concerns/telegram_notifiable.rb
module TelegramNotifiable
  extend ActiveSupport::Concern

  included do
    has_many :telegram_subscriptions, dependent: :destroy
    encrypts :telegram_bot_token
    validates :telegram_bot_username, format: { with: /\A[a-zA-Z0-9_]+\z/ }, allow_blank: true
  end

  def telegram_configured?
    telegram_bot_token.present? && telegram_bot_username.present?
  end

  def telegram_send_message(chat_id, text, **options)
    # ...
  end

  # ... all other telegram_* methods
end
```

Then in Agent: `include TelegramNotifiable`. Done.

### 2. `find_agent_by_webhook_token` is a table scan

```ruby
Agent.find_each.detect { |a| a.telegram_configured? && a.webhook_token == token }
```

The spec acknowledges this is bad and hand-waves it as "a refinement for later." No. This is a webhook endpoint called by Telegram on every message. It decrypts every agent's bot token to compute a hash comparison. This is not a performance optimization -- it is a correctness issue. If you have 50 agents, you are doing 50 decryptions per webhook call.

The fix is trivial: store `webhook_token` as a column. It is derived from the agent ID and bot token -- it is not secret. Add it to the migration, set it in a `before_save` callback when `telegram_bot_token` changes, and look it up directly:

```ruby
Agent.find_by(telegram_webhook_token: params[:token])
```

Do this from the start. "Later" never comes.

### 3. Deep link using Base64-encoded user IDs is fragile

Encoding a raw user ID as a Base64 string is not great. Anyone can decode it, and anyone can forge a registration link for any user. The spec says "not secret, but sufficient for matching" -- but this means any Telegram user who guesses or obtains another user's ID can subscribe as that user.

Use a signed token instead:

```ruby
# Generate
Rails.application.message_verifier(:telegram_deep_link).generate(user.id, expires_in: 7.days)

# Verify
Rails.application.message_verifier(:telegram_deep_link).verified(param)
```

This is a one-line change in each direction, uses Rails built-in infrastructure, and actually provides security. No reason not to.

## Improvements Needed

### 4. Webhook setup belongs in a callback, not the controller

The spec puts webhook management logic in the controller's `update` action:

```ruby
def update
  token_changed = @agent.telegram_bot_token != agent_params[:telegram_bot_token]
  if @agent.update(agent_params)
    @agent.set_telegram_webhook! if token_changed && @agent.telegram_configured?
```

This is controller logic that belongs in the model. Use an `after_update_commit` callback:

```ruby
after_update_commit :manage_telegram_webhook, if: :saved_change_to_telegram_bot_token?

private

def manage_telegram_webhook
  telegram_configured? ? set_telegram_webhook! : delete_telegram_webhook!
end
```

Now any code path that updates the agent (console, API, future admin panel) will correctly manage the webhook. The controller stays thin.

### 5. `notify_subscribers!` iterates all account users unnecessarily

```ruby
def notify_subscribers!(message_record, chat)
  return unless telegram_configured?
  account.users.each do |user|
    subscription = telegram_subscriptions.find_by(user: user, blocked: false)
    next unless subscription
    TelegramNotificationJob.perform_later(subscription, message_record, chat)
  end
end
```

Why load all users just to find which ones have subscriptions? Query the subscriptions directly:

```ruby
def notify_subscribers!(message, chat)
  return unless telegram_configured?
  telegram_subscriptions.active.each do |subscription|
    TelegramNotificationJob.perform_later(subscription, message, chat)
  end
end
```

Simpler, faster, and more obvious.

### 6. The `blocked` boolean on TelegramSubscription

A boolean `blocked` column with a default of `false` is fine for now, but consider: when a user unblocks the bot, they will send `/start` again, and the existing code already handles this by setting `blocked: false`. So this works. No issue here -- just confirming the design is sound.

### 7. The `telegram_username` and `telegram_first_name` columns

Are these used anywhere? They are stored but never referenced in the spec. If they are purely informational (for an admin to see who subscribed), fine. But do not store data you have no plan to use. If the only purpose is debugging, log it instead.

### 8. Error handling in `telegram_send_message` is inconsistent

```ruby
raise TelegramError, result["description"] if response.code.to_i == 403
Rails.logger.error "[Telegram] sendMessage failed: #{result['description']}"
```

So a 403 raises, but a 500 or 400 just logs? This means if Telegram is down, notifications silently fail with no retry. The job has `retry_on Agent::TelegramError`, but that error is only raised for 403s. Either raise for all failures (and let the job retry), or be explicit about which failures are transient vs permanent.

### 9. The `TelegramError` class is nested inside Agent

`Agent::TelegramError` is odd. If you extract the concern, this becomes `TelegramNotifiable::TelegramError` or just a top-level `TelegramError`. Either way, nesting an error class inside a model that is not primarily about Telegram is a smell.

## What Works Well

- **No gems, no service objects** -- exactly right for this scope
- **Solid Queue jobs for async work** -- clean separation
- **Encrypted bot tokens** -- proper use of Rails 8 encryption
- **Webhook secret verification** -- correct use of `secure_compare`
- **Testing strategy** -- covers the right scenarios at the right levels
- **Edge cases section** -- thoughtful and complete
- **Trigger points are well-identified** -- `initiate_by_agent!` and `ManualAgentResponseJob`

## Summary of Required Changes

1. Extract all Telegram logic into a `TelegramNotifiable` concern
2. Store `webhook_token` as a database column from the start
3. Use `Rails.application.message_verifier` for deep link tokens instead of raw Base64
4. Move webhook management to an `after_update_commit` callback
5. Query subscriptions directly in `notify_subscribers!` instead of iterating users
6. Fix error handling to raise on all API failures, not just 403
7. Justify or remove `telegram_username`/`telegram_first_name` columns
