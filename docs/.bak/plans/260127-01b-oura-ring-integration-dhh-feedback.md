# DHH Review: Oura Ring Integration Spec v01b

**Reviewer**: DHH-style review
**Date**: 2026-01-27
**Verdict**: This is ready to ship. Well done.

---

## Overall Assessment

Version 01b demonstrates exactly how to respond to feedback: address the issues directly, resist the urge to add compensating complexity, and emerge with something cleaner than before. The schema dropped from 12 columns to 7. OAuth state moved to session where it belongs. The context injection went from an N+1 query dance to a simple `account.owner&.oura_health_context`. The granular sharing toggles are gone in favor of a single `enabled` flag.

This is now a proper MVP. It does one thing well: connect Oura, sync health data, inject it into prompts. No speculative features, no unnecessary configuration options, no premature abstractions.

---

## Previous Issues: Resolution Status

| Issue from 01a | Status | Notes |
|----------------|--------|-------|
| `access_token_ciphertext` naming | Fixed | Now just `access_token` - Rails encryption handles the rest |
| OAuth state in database | Fixed | Moved to session with expiration |
| Unnecessary `scopes` column | Fixed | Removed entirely |
| Granular sharing toggles | Fixed | Single `enabled` toggle |
| Model too fat | Fixed | HTTP concerns extracted to `OuraApi` module |
| Context injection complexity | Fixed | Simple `account.owner&.oura_health_context` |
| Error class location | Fixed | `OuraApi::Error` inside the concern |
| Route naming (plural vs singular) | Fixed | Now singular `resource :oura_integration` |

Every issue addressed. No regressions introduced.

---

## What Works Well

### 1. The Schema Is Right-Sized

```ruby
create_table :oura_integrations do |t|
  t.references :user, null: false, foreign_key: true, index: { unique: true }
  t.text :access_token
  t.text :refresh_token
  t.datetime :token_expires_at
  t.jsonb :health_data, default: {}
  t.datetime :health_data_synced_at
  t.boolean :enabled, default: true, null: false
  t.timestamps
end
```

Seven columns. Nothing speculative. Everything earns its place.

### 2. Clean Separation of Concerns

The `OuraApi` concern handles HTTP operations. The `OuraIntegration` model handles persistence and business logic. The controller handles session state and request/response orchestration. Each layer does its job without reaching into the others.

### 3. OAuth State in Session

```ruby
def create
  state = SecureRandom.hex(32)
  session[:oura_oauth_state] = state
  session[:oura_oauth_state_expires_at] = 10.minutes.from_now.to_i
  # ...
end

def callback
  expected_state = session.delete(:oura_oauth_state)
  expires_at = session.delete(:oura_oauth_state_expires_at)
  # ...
end
```

This is the Rails way. Session state for ephemeral flow data, database for persistent data. The state is created, used once, and immediately deleted. No stale data accumulating in the database.

### 4. Context Injection Is Surgical

```ruby
if (health_context = account.owner&.oura_health_context)
  parts << health_context
end
```

One line. No new private method. No complex user lookup. It slots cleanly into the existing `system_message_for` method. This is what good code looks like: invisible until you need it.

### 5. The Single Toggle Respects User Intelligence

One switch: "Share health data with AI agents." Users either want this feature or they do not. They are not going to micromanage which data types flow through. If they ever do request that control, adding columns is a 5-minute migration. But until then, the simpler UI wins.

### 6. Error Handling Is Proportionate

401 responses clear tokens and return nil. Rate limits log and return nil. Token revocation is best-effort with a rescue clause. No elaborate retry logic, no circuit breakers, no error tracking gems. The code handles failures gracefully without overcomplicating the happy path.

---

## Minor Observations

### 1. Consider Inline Token Refresh

The current flow calls `refresh_tokens!` separately:

```ruby
def sync_health_data!
  refresh_tokens! unless token_fresh?
  return unless connected?
  # ...
end
```

This is fine. An alternative would be to refresh lazily inside `fetch_endpoint` when a 401 is encountered, but the current approach is explicit and easier to reason about. Keep it as is.

### 2. The Concern Could Be a Module

`OuraApi` is implemented as an `ActiveSupport::Concern`, which is appropriate since it uses `included do` for the encryption declarations. The alternative would be a plain module with `extend ActiveSupport::Concern`, but the current approach is idiomatic.

### 3. Health Data Keys Are Strings in Some Places, Symbols in Others

```ruby
# In fetch_health_data (returns strings)
{
  "sleep" => fetch_endpoint(...),
  "readiness" => fetch_endpoint(...),
  "activity" => fetch_endpoint(...)
}

# In format_sleep_context (uses strings)
health_data.dig("sleep")
```

This is consistent within the file, which is what matters. The JSONB column will store strings anyway, so using strings throughout is correct.

---

## What Not to Add

Resist the temptation to:

1. **Add webhook support before polling proves insufficient** - 6-hour polling is fine for health data that changes once per day
2. **Add per-agent health data toggles** - If users want this, they will ask
3. **Add historical trend visualization** - Out of scope for MVP
4. **Abstract to support multiple wearables** - YAGNI until you have a second wearable to support

The "Future Enhancements" section correctly identifies these as out of scope. Keep them there.

---

## Verdict: Ship It

This spec is ready for implementation. It follows Rails conventions, keeps complexity proportionate to the problem, and resists the urge to build for hypothetical futures. The code would not look out of place in a Rails guide.

The test coverage is comprehensive. The UI is simple and focused. The data flow is clear. The error handling is sensible.

Build it exactly as specified. Do not add features. Do not add configuration options. Do not add abstractions "just in case." Ship the MVP, put it in front of users, and iterate based on real feedback.

This is how you build software that lasts.
