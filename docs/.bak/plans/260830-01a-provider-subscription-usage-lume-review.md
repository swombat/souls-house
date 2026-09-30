# Lume review — Plan 260830-01a (provider subscription usage)

**Date:** 2026-08-30
**Reviewing:** `260830-01a-provider-subscription-usage.md`
**Lens:** elegance / Rails-like minimalism, extensibility

**Overall:** already restrained. The non-goals list does real work, the runtime/Rails boundary follows the auth plan cleanly, and the `USAGE_PROBES` dict is the right amount of extensibility. Two changes, one verification, then answers to the five questions.

---

## 1. Load-bearing simplification: gate in `/trigger`, not in Rails

The plan has two mechanisms for the same decision: a Rails preflight (`GET /auth/usage` before every human turn, across three call sites) *and* a postflight `error_kind: subscription_limit` classification (needed anyway for the race). Postflight alone can carry it.

The shim already receives `provider` + `model` on `/trigger`, and it owns the cache. So: `/trigger` checks the cache itself, and if `limited`, returns immediately with `{error_kind: "subscription_limit", subscription_usage: {...}}` without launching Chaos. Rails then has exactly **one** path — classify the result — and:

- no new preflight branch in `ExternalAgentResponseRequest`, `ExternalAgentTelegramRequest`, or the background jobs;
- no extra HTTP round-trip per turn (the `record_trigger!` block stays one call);
- "one in-flight refresh per key" is trivially true because the only caller is the runtime;
- `GET /auth/usage` shrinks to what it really is: a settings-panel read.

Preflight in Rails only buys the ability to skip *recording* an `AgentRuntimeInteraction` for a doomed turn — and that record is probably wanted anyway.

Background triggers "skip quietly" for free under this shape: they receive the error body and don't post. No code.

## 2. Make `error_kind` the vocabulary; retire the existing regex

The plan says "Rails should not grow four stderr regexes" — but Rails already has one: `subscription_auth_failure?` in `app/lib/external_agent_response_request.rb` (line 67), matching `/unauthori[sz]ed|authentication|…\b401\b/` against stdout/stderr, with a Gemini-warning exclusion bolted on. The plan then keeps auth-expiry "separate". That's the seam to close: have the shim classify *both* — `error_kind: "auth_expired"` and `"subscription_limit"` — and Rails does one `case`:

```ruby
case result.dig(:body, "error_kind")
when "auth_expired"       then surface_auth_expiry!
when "subscription_limit" then surface_subscription_limit!(result[:body]["subscription_usage"])
end
```

The regex moves into the shim beside the provider protocol it parses. A third failure kind later is one branch. The runtime speaks in kinds; Rails speaks in copy.

Related: `AgentSubscriptionUsage.for(agent)` makes a network call *and* is a value object. Split it — `AgentSubscriptionUsage.new(hash)` wraps a snapshot (from either the usage endpoint or the trigger error body) and knows `limited?`, `resets_at`, `user_message(time_zone:)`. Transport stays in `AgentProviderAuthClient#usage`. The same PORO then formats the settings row and the chat message from the same hash.

## 3. Verify before building on it: the CodexBar Linux CLI

Two of four providers (Claude, Antigravity) rest on "CodexBar Linux CLI, pinned amd64/arm64 release". CodexBar is known as a macOS menubar app; the plan never says the Linux CLI has been confirmed to exist with those artifacts. That's a load-bearing external assumption in steps 6–7. Check it first. If it isn't there, the Claude probe is likely a direct call with the clamp's OAuth token (same shape as the Grok/OpenAI Chaos path), and the source table simplifies rather than complicates.

## Smaller

- `used_percent` and `remaining_percent` in the same window: pick one.
- `label: "Weekly"` is presentation leaking from the runtime — acceptable, but Rails could derive it from `id`.
- Separate `ProviderSubscriptionUsagesController` rather than another `?capabilities`-style flag: agree; the existing flag is already the smell.
- "Requesting user's time zone when available" — confirm `User` actually has one. If not, that's "always UTC" and the copy should be written for it.

## Answers to the five questions

1. **Credential-owner split** — clean, *if* #3 holds. If CodexBar Linux doesn't exist, the split still holds conceptually but the Claude leg becomes "the clamp's own token, read directly".
2. **Fail open on `unknown`** — yes, for all providers, no exceptions. Stricter behaviour turns a monitoring bug into an outage, which is exactly the failure being replaced.
3. **No persisted cooldown** — correct. With gating in the runtime it's even clearer: the shim's cache *is* the cooldown, and it dies with the container, which is the right lifetime for live state.
4. **UI rows** — show all informative rows, mark blocking ones. Someone connecting a Claude subscription wants to see the weekly pool even when the session pool is what's blocking. Gating uses `blocking` only — already in the plan.
5. **Provenance** — `source`, `observed_at`, `blocking` is enough. Add nothing. The one thing to *remove* is the Rails-side preflight (#1), which also removes any temptation to read `source` in Rails.

**Net:** same feature, one fewer HTTP call per turn, three fewer branches in Rails, and the existing auth regex retired instead of joined by a sibling.
