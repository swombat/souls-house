# Code Review: Telegram Notifications Implementation

## Overall Assessment

This is clean, well-structured Rails code that follows the codebase's established patterns faithfully. The concern-based approach, thin controller, and job decomposition all feel right. The implementation matches the spec nearly line-for-line, which is both its strength and its limitation -- it was executed with discipline but there are a few rough edges worth addressing. This is close to Rails-worthy; a handful of fixes would get it there.

## Critical Issues

### 1. `manage_telegram_webhook` makes HTTP calls inside an `after_update_commit` callback

**File:** `/Users/danieltenner/dev/helix_kit/app/models/concerns/telegram_notifiable.rb`, line 85

`set_telegram_webhook!` and `delete_telegram_webhook!` both make synchronous `Net::HTTP` calls to the Telegram API. Doing this inside a model callback means every save that touches `telegram_bot_token` blocks the request thread until Telegram responds (or times out). If Telegram is slow or down, the user's browser hangs on the agent edit form.

This should be a job:

```ruby
after_update_commit :enqueue_telegram_webhook_management, if: :saved_change_to_telegram_bot_token?

def enqueue_telegram_webhook_management
  ManageTelegramWebhookJob.perform_later(self)
end
```

### 2. No timeout on `Net::HTTP.post`

**File:** `/Users/danieltenner/dev/helix_kit/app/models/concerns/telegram_notifiable.rb`, line 72

`Net::HTTP.post` with no timeout configuration means Ruby's default 60-second read timeout applies. Combined with the callback issue above, this is a recipe for hanging requests. Even after moving to a job, add explicit timeouts:

```ruby
def telegram_api_request(method, body)
  uri = URI("https://api.telegram.org/bot#{telegram_bot_token}/#{method}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 5
  http.read_timeout = 10

  request = Net::HTTP::Post.new(uri)
  request["Content-Type"] = "application/json"
  request.body = body.to_json

  response = http.request(request)
  JSON.parse(response.body)
end
```

### 3. `set_telegram_webhook_token` uses `id` which is `nil` on new records

**File:** `/Users/danieltenner/dev/helix_kit/app/models/concerns/telegram_notifiable.rb`, line 79

The `before_save` callback calls `Digest::SHA256.hexdigest("#{id}-#{telegram_bot_token}")`. On a brand new agent that has never been saved, `id` is `nil`, producing `"nil-sometoken"` as the hash input. This is fragile. If the agent is later updated without changing the token, the webhook token stays as the nil-derived hash, which is wrong.

Consider using `before_save` only when `persisted?`, or switching to `after_save` and updating the column in a separate step, or using `SecureRandom.hex(16)` instead of deriving from `id`.

## Improvements Needed

### 4. Heredoc indentation in `TelegramNotificationJob`

**File:** `/Users/danieltenner/dev/helix_kit/app/jobs/telegram_notification_job.rb`, lines 16-19

The `<<~HTML` squiggly heredoc strips leading whitespace based on the least-indented line. Since the content lines are indented with 6 spaces (inside the method body), and `<<~` strips that, the output is correct. But mixing HTML tags with heredoc feels slightly off. This is minor -- the code reads fine.

### 5. `notify_subscribers!` loads all active subscriptions eagerly

**File:** `/Users/danieltenner/dev/helix_kit/app/models/concerns/telegram_notifiable.rb`, line 59

`telegram_subscriptions.active.each` loads all subscriptions into memory. For now this is fine (few subscribers per agent), but `find_each` would be more Rails-idiomatic for a method that enqueues jobs:

```ruby
def notify_subscribers!(message, chat)
  return unless telegram_configured?

  telegram_subscriptions.active.find_each do |subscription|
    TelegramNotificationJob.perform_later(subscription, message, chat)
  end
end
```

### 6. `telegram_webhook_secret` returns raw bytes

**File:** `/Users/danieltenner/dev/helix_kit/app/models/concerns/telegram_notifiable.rb`, line 53

`generate_key` returns a binary string. The Telegram API expects `secret_token` to be 1-256 characters from `[A-Za-z0-9_-]`. Raw bytes will contain non-ASCII characters. This will likely cause the webhook setup to fail silently (the error is logged but not surfaced). Use `generate_key` and then hex-encode or Base64url-encode the result:

```ruby
def telegram_webhook_secret
  key = Rails.application.key_generator.generate_key("telegram_webhook_secret:#{id}", 32)
  Base64.urlsafe_encode64(key, padding: false)
end
```

This is potentially a **bug**, not just an improvement.

### 7. `ProcessTelegramUpdateJob` uses `dig` unnecessarily for single-level access

**File:** `/Users/danieltenner/dev/helix_kit/app/jobs/process_telegram_update_job.rb`, lines 6-9

`update.dig("message")` is just `update["message"]`. `dig` is for nested access. Minor, but idiomatic Ruby uses `[]` for single-key lookups:

```ruby
message = update["message"]
return unless message

text = message["text"]
```

### 8. `chat_url` construction in `TelegramNotificationJob` should use Rails URL helpers

**File:** `/Users/danieltenner/dev/helix_kit/app/jobs/telegram_notification_job.rb`, line 13

Manually building URLs with string interpolation is fragile. Use `Rails.application.routes.url_helpers`:

```ruby
chat_url = Rails.application.routes.url_helpers.account_chat_url(
  chat.account_id, chat,
  host: Rails.application.credentials.dig(:app, :url)
)
```

Or at minimum, include the URL helpers in the job. Hand-crafted URLs break when routes change.

## What Works Well

- **Concern placement is perfect.** All Telegram logic on the Agent model, extracted into a concern. This is exactly the Rails way -- the Agent gains Telegram capabilities without cluttering its core responsibilities.

- **Security is thorough.** Encrypted bot tokens, HMAC-based webhook secrets with `secure_compare`, signed deep links with expiry, account-scoped user verification. Every attack vector is addressed.

- **The controller is beautifully thin.** `TelegramWebhooksController` does exactly three things: find the agent, verify the secret, enqueue the job. No business logic leaked in.

- **`TelegramSubscription` is minimal.** Two associations, one scope, one method. This is a model that knows its place.

- **Error handling in `TelegramNotificationJob` is smart.** Catching "blocked"/"chat not found" to mark subscriptions blocked, re-raising everything else for retry -- this is production-aware code.

- **The trigger points are well-chosen.** `tap` after the transaction in `initiate_by_agent!` ensures notifications fire only after the commit. The callback in `ManualAgentResponseJob` fires only when the message is persisted. Both are correct.

- **The route is clean and sits in the right place** -- outside the account scope, since Telegram calls it directly.

- **Spec adherence is excellent.** The implementation matches the plan with no drift or scope creep.

## Summary of Action Items

| Priority | Issue | File |
|----------|-------|------|
| High | Move webhook management to a job (blocks request thread) | `telegram_notifiable.rb` |
| High | Fix `telegram_webhook_secret` encoding (likely bug) | `telegram_notifiable.rb` |
| High | Fix `id` being nil in `set_telegram_webhook_token` for new records | `telegram_notifiable.rb` |
| Medium | Add explicit timeouts to `Net::HTTP` calls | `telegram_notifiable.rb` |
| Low | Use `find_each` instead of `each` in `notify_subscribers!` | `telegram_notifiable.rb` |
| Low | Use URL helpers instead of string interpolation for `chat_url` | `telegram_notification_job.rb` |
| Low | Use `[]` instead of `dig` for single-level hash access | `process_telegram_update_job.rb` |
