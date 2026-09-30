# DHH Review: Telegram Notifications Spec (v2)

## Overall Assessment

This is a dramatically improved spec. Every critical issue from the first review has been addressed: the concern extraction, the webhook token column, signed deep links, model callbacks, direct subscription querying, and the dropped unused columns. The architecture is now clean and Rails-worthy. What remains are smaller issues -- a few places where the code could be tighter or where edge cases are not fully handled.

## Issues

### 1. `telegram_api_request` silently returns a hash on failure

`telegram_send_message` raises on a non-ok response, but `set_telegram_webhook!` and `delete_telegram_webhook!` call `telegram_api_request` and do nothing with the result. If `setWebhook` fails (bad token, Telegram down), the agent saves successfully and the user sees no feedback. The webhook silently does not exist.

This matters because `manage_telegram_webhook` runs in `after_update_commit` -- the save has already happened. You cannot roll it back. But you can at least log the failure or broadcast an error. At minimum, check the result:

```ruby
def set_telegram_webhook!
  return unless telegram_configured?

  result = telegram_api_request("setWebhook", {
    url: webhook_url,
    allowed_updates: ["message"],
    secret_token: telegram_webhook_secret
  })

  Rails.logger.error("[Telegram] setWebhook failed: #{result['description']}") unless result["ok"]
end
```

Same for `delete_telegram_webhook!`. Silent failures in callbacks are a debugging nightmare.

### 2. `telegram_webhook_secret` is deterministic from the bot token

```ruby
def telegram_webhook_secret
  Digest::SHA256.hexdigest("#{telegram_bot_token}-webhook-secret")[0..31]
end
```

This is fine functionally, but the string `"-webhook-secret"` as a salt is weak. If someone obtains the bot token (which Telegram shows in plaintext to the bot owner), they can compute the webhook secret trivially. Use `Rails.application.key_generator` instead:

```ruby
def telegram_webhook_secret
  Rails.application.key_generator.generate_key("telegram_webhook_secret:#{id}", 32)
end
```

This derives from the app's secret key base, making it impossible to forge even with the bot token. One line, stronger security.

### 3. `request.body.read` in the controller may conflict with params parsing

```ruby
update = JSON.parse(request.body.read)
```

Rails may have already consumed `request.body` during parameter parsing. Since you skip CSRF but Rails still parses the body for `params`, `request.body.read` could return an empty string. Use `request.raw_post` instead, which is cached:

```ruby
update = JSON.parse(request.raw_post)
```

Or even simpler -- just use `params` directly. Rails already parses JSON request bodies into `params`. You could do:

```ruby
ProcessTelegramUpdateJob.perform_later(agent.id, params.except(:token, :controller, :action).to_unsafe_h)
```

But `request.raw_post` is cleaner and avoids the `to_unsafe_h` dance.

### 4. The deep link is generated per-user but shown on the agent edit page

The spec says the deep link is passed as a prop from the controller, generated for `current_user`. But this is the agent configuration page -- presumably used by an admin. The registration link shown will be specific to that admin user, not a generic link for all users.

Is the intent that each user gets their own link from somewhere else in the UI? If so, the edit page should not show a registration link at all -- it should show instructions about where users find their link. If the intent is that the admin shares a single link, then the deep link should not be user-specific.

Clarify the UX. This is a design question, not a code question, but it will determine whether the current implementation is correct.

### 5. `ProcessTelegramUpdateJob` takes `agent_id` but `TelegramNotificationJob` takes `subscription`

```ruby
ProcessTelegramUpdateJob.perform_later(agent.id, update)
TelegramNotificationJob.perform_later(subscription, message, chat)
```

The first passes an ID, the second passes ActiveRecord objects. Pick one convention. Passing objects is fine -- Rails serializes them via GlobalID. But be consistent. Either pass IDs everywhere or objects everywhere. Since `TelegramNotificationJob` already takes objects, change `ProcessTelegramUpdateJob` to take the agent directly:

```ruby
ProcessTelegramUpdateJob.perform_later(agent, update)
```

### 6. `verify_deep_link` scopes to `agent.account.users` -- good, but undocumented

The spec correctly scopes user lookup to the agent's account:

```ruby
agent.account.users.find_by(id: user_id)
```

This is an important security boundary -- a valid signed token from one account cannot be used to register against an agent in a different account. Worth a one-line comment in the edge cases section. It is the kind of subtle correctness that gets lost in future refactors.

### 7. Minor: `find_or_initialize_by` followed by `update!`

```ruby
subscription = agent.telegram_subscriptions.find_or_initialize_by(user: user)
subscription.update!(telegram_chat_id: chat_id, blocked: false)
```

This is two queries when one suffices. Use `find_or_create_by` with an `upsert`, or more idiomatically:

```ruby
agent.telegram_subscriptions.upsert(
  { user_id: user.id, telegram_chat_id: chat_id, blocked: false },
  unique_by: [:agent_id, :user_id]
)
```

One query. Though the `find_or_initialize_by` + `update!` pattern is perfectly readable and runs validations, so this is a preference, not a requirement.

## What Works Well

- **Concern extraction is clean** -- `TelegramNotifiable` is cohesive and well-scoped
- **`before_save` / `after_update_commit` split** -- webhook token computed before save, webhook registered after commit. Correct ordering.
- **Signed deep links with expiry** -- proper use of `message_verifier`
- **Direct subscription querying** -- `telegram_subscriptions.active.each` is exactly right
- **Dropped unused columns** -- no `telegram_username`, no `telegram_first_name`. Lean.
- **Error handling in notification job** -- raises for retryable errors, marks blocked for permanent ones
- **Testing strategy** -- comprehensive and at the right abstraction levels

## Summary

This spec is ready to implement. The remaining issues are:

1. Log failures in `set_telegram_webhook!` and `delete_telegram_webhook!`
2. Use `key_generator` for webhook secret instead of a simple hash
3. Use `request.raw_post` instead of `request.body.read`
4. Clarify the deep link UX -- who sees it, where, and for whom
5. Be consistent about passing IDs vs objects to jobs
