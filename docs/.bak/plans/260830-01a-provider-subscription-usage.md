# Plan 260830-01a — Provider subscription usage and limit handling

**Date:** 2026-08-30

**Status:** Implemented; hosted-provider acceptance pending deployment

**Initial providers:** Grok/xAI, Gemini/Antigravity, Claude/Anthropic, OpenAI/Codex

**Related:** `docs/plans/260726-02a-provider-subscription-auth.md`, `docs/plans/260802-01b-anthropic-subscription-clamp.md`, `docs/plans/260830-01a-provider-subscription-usage-lume-review.md`

---

## Goal

Show the remaining headroom and reset time for a hosted resident's connected
subscription, and give a human a clear answer when that subscription is
exhausted instead of launching a doomed turn or reporting that the runtime is
unreachable.

The immediate case is Grok: if Paulina asks Grok something while its subscription
is exhausted, souls.house should answer in the conversation:

> _Grok's subscription limit has been reached. It should reset at 12:32 AM._

The same shape should work for Gemini, Claude, and OpenAI without teaching Rails
four provider protocols.

---

## Design in one sentence

**The resident runtime reads subscription usage beside the credentials, gates
turns there, and returns one small provider-independent snapshot that Rails uses
for presentation.**

This follows the boundary established by provider subscription auth:

- provider credentials remain inside the resident's private runtime volumes;
- provider-specific probing remains runtime machinery;
- Rails owns user-facing policy and copy;
- no quota credential, provider response, or browser session enters the
  souls.house database.

---

## Deliberately small architecture

### Runtime contract

Add one bearer-authenticated, settings-only endpoint to
`agent-runtime/trigger_shim.py`:

```text
GET /auth/usage?provider=xai&model=grok-build
```

It returns an allowlisted response:

```json
{
  "provider": "xai",
  "plan": "SuperGrok",
  "status": "limited",
  "windows": [
    {
      "id": "subscription",
      "label": "Weekly",
      "remaining_percent": 0.0,
      "resets_at": "2026-08-30T22:32:46Z",
      "blocking": true
    }
  ],
  "observed_at": "2026-08-30T17:08:29Z",
  "source": "grok-oauth"
}
```

`status` is one of:

- `available` — a fresh authoritative reading says the selected model can run;
- `limited` — a fresh authoritative blocking window is exhausted;
- `unknown` — the provider could not be checked safely.

Only `limited` blocks a turn. `unknown` fails open and lets the ordinary provider
request decide. A monitoring failure must never become a service outage.

`blocking` keeps provider/model-specific knowledge in the runtime. Rails does not
need to know whether a Claude model-specific weekly lane, an Antigravity Gemini
pool, or a general Grok credit pool applies to the selected model.

`GET /auth/usage` exists for the settings panel. It is not called as a Rails
preflight before a turn. The existing `/trigger` endpoint uses the same cache
accessor internally, refreshing on a cache miss or expiry, and gates only
`oauth_account` requests:

- `available` or `unknown` → launch Chaos normally;
- `limited` → return HTTP 429 immediately, without launching Chaos:

```json
{
  "error_kind": "subscription_limit",
  "subscription_usage": {
    "provider": "xai",
    "status": "limited",
    "windows": []
  }
}
```

This keeps a turn to one Rails→runtime request. The existing
`AgentRuntimeInteraction` records the refused attempt, which is useful
operational evidence rather than something to avoid.

### No plugin framework

Implement a small dispatch table and four ordinary probe functions in the shim,
for example:

```python
USAGE_PROBES = {
    "anthropic": probe_claude_usage,
    "gemini": probe_antigravity_usage,
    "openai": probe_chaos_account_usage,
    "xai": probe_chaos_account_usage,
}
```

Do not introduce dynamic provider loading, a provider DSL, background workers, or
a separate usage service. A fifth provider should require one function and one
registry entry. If the table becomes genuinely unwieldy later, extract it then.

---

## Where each initial reading comes from

The source should follow the owner of the credential.

| souls.house provider | Runtime source | Reason |
|---|---|---|
| `xai` (Grok) | `chaos accounts usage --json`, using the existing xAI OAuth account | Chaos owns and refreshes this token. The xAI login already requests `grok-cli:access`; use the same subscription billing surface CodexBar's Grok provider uses. |
| `openai` | `chaos accounts usage --json`, using the existing ChatGPT OAuth account | Chaos owns its multi-provider `auth.json`; CodexBar expects Codex's different native auth shape. Do not copy or translate credentials into a second persistent store. |
| `anthropic` (Claude) | CodexBar Linux CLI, Claude provider, against the resident's `CLAUDE_CONFIG_DIR` | The authoritative subscription session belongs to the official Claude Code clamp, outside Chaos account storage. |
| `gemini` | CodexBar Linux CLI, Antigravity provider, against the resident's `CHAOS_AGY_HOME` and pinned `agy` binary | The authoritative quota summary is exposed by the official Antigravity CLI and contains separate Gemini and Claude/GPT five-hour and weekly pools. |

### Why a small Chaos command is preferable for OpenAI and Grok

Add a read-only upstream command:

```text
chaos --provider xai accounts usage --json
chaos --provider openai accounts usage --json
```

It should:

1. load and refresh the provider account through Chaos's existing auth manager;
2. make the provider's usage request;
3. return plan plus rate windows using Chaos's existing
   `RateLimitSnapshot`/window vocabulary;
4. emit no access token, refresh token, account id, or raw provider body.

For OpenAI, use the same `wham/usage` account surface already represented by
CodexBar and map primary/secondary/additional rate limits.

For xAI, use the existing `grok-cli:access` OAuth token against the subscription
billing surface represented by CodexBar's Grok implementation. Verify this
against a real hosted Grok account before treating the probe as complete. If xAI
rejects Chaos's client token despite the scope, fix the Chaos OAuth/usage
integration; do **not** add a second Grok login ceremony or copy browser cookies
into the resident.

This command is the extensible seam for future Chaos-managed OAuth providers.
Clamp-managed providers continue to use their first-party harnesses.

### CodexBar in the runtime image

The Linux assumption was verified on 2026-08-30 before retaining this design:

- the current official release, `v0.56.1`, publishes glibc and musl CLI tarballs
  for both `x86_64` and `aarch64`;
- the official `aarch64` glibc tarball was downloaded and its published SHA-256
  verified successfully;
- the extracted executable is an ELF 64-bit ARM Linux binary and reports
  version `0.56.1`;
- CodexBar's release workflow builds and smoke-tests the four Linux target
  combinations; and
- the Claude and Antigravity CLI session implementations explicitly support
  glibc and musl.

Authenticated execution inside the resident Linux container remains a live
acceptance requirement; the release artifact itself is no longer an unverified
architectural assumption.

Install the official Linux CLI in `agent-runtime/Dockerfile`:

- pin an exact release and SHA-256 for `amd64` and `arm64`;
- copy its MIT licence notice into the image/repository;
- install `lsof`, required by the Antigravity CLI probe;
- verify `codexbar --version` at build time;
- invoke it as a one-shot subprocess, not as a second HTTP daemon.

Use explicit providers and sources so the result never depends on a user's
ambient CodexBar configuration:

```text
codexbar usage --provider claude --source cli --format json
codexbar usage --provider antigravity --source cli --format json
```

These are usage probes, not login flows. Before invoking CodexBar, the shim
checks the existing provider connection with the same credential-local status
path already used by `/auth/status`. A missing or expired connection returns
`status: unknown`; the probe must never start OAuth, display a device code, open
a browser, or write replacement credentials. An actual turn may separately
return `error_kind: auth_expired`. Reconnection continues to use the existing
souls.house `/auth/start` ceremony.

The shim supplies only the relevant environment:

- Claude: `CLAUDE_CONFIG_DIR`, no `ANTHROPIC_API_KEY`;
- Antigravity: the resident's private Antigravity home, `AGY_BIN`, and no Gemini
  API key.

Bound each subprocess by time and output size. Parse JSON only. Never return raw
stdout/stderr to Rails.

---

## Runtime freshness and caching

Keep a process-local cache in `trigger_shim.py`, keyed by `(provider, model)`:

- successful snapshots: 60-second TTL;
- one in-flight refresh per key;
- no cache persistence and no new database;
- after `resets_at`, an old exhausted snapshot becomes `unknown`, never an
  indefinite block;
- a failed refresh may return a recent last-good snapshot only while its reset
  boundary is still in the future, marked with its original `observed_at`;
- otherwise return `status: unknown`.

Sixty seconds avoids starting a CLI probe for every page render or trigger while
remaining short enough for a reset to become visible promptly.

The runtime should refresh or replace the cache opportunistically when a real
turn supplies newer rate-limit evidence.

---

## Rails shape

### One resource

Add a nested read-only resource:

```text
GET /accounts/:account_id/agents/:agent_id/provider_subscription_usage
```

`Agents::ProviderSubscriptionUsagesController#show`:

1. uses the existing `AgentScoped` and account authorization;
2. derives provider and Chaos model from the agent;
3. calls `AgentProviderAuthClient#usage(provider:, model:)`;
4. returns the normalized runtime response unchanged.

Keeping this separate from `ProviderSubscriptionsController` avoids adding
another query-mode branch to the connection ceremony controller while retaining
the existing client and bearer-auth plumbing.

### One value object

Add a small `AgentSubscriptionUsage` PORO for formatting normalized snapshots:

```ruby
usage = AgentSubscriptionUsage.new(snapshot_hash)

usage.limited?
usage.resets_at
usage.user_message(time_zone: current_user.timezone)
```

It wraps a snapshot received either from `AgentProviderAuthClient#usage` or a
`/trigger` error body. It makes no network request and contains no
provider-specific endpoint or credential logic. It may know provider display
names (`xai` → `Grok`) and message wording; it should not know how Grok or Claude
calculates quota.

Do not persist usage snapshots in `agents.provider_connections` or add a quota
table. This is live operational state, not account configuration.

---

## User-facing request handling

### Gate inside `/trigger`

Rails keeps its existing single trigger call. For an `oauth_account` request,
the shim checks the shared usage cache before launching Chaos. A fresh
`limited` snapshot returns the normalized HTTP 429 response above; `available`
and `unknown` proceed.

There is no usage preflight branch in `ExternalAgentResponseRequest`,
`ExternalAgentTelegramRequest`, or background jobs. Human request handlers
surface the normalized failure. Background wakes/orientation/memory work
receive the same result and stop without posting a chat message.

Do not add a persisted cooldown column in this iteration. The runtime cache and
provider reset timestamp already prevent repeated expensive probes and doomed
turns. Add durable cooldown state only if scheduler traffic later proves this
insufficient.

### One failure vocabulary

The runtime classifies both a usage gate and provider failures discovered after
launching Chaos:

```json
{
  "error_kind": "subscription_limit",
  "subscription_usage": { "...": "present for subscription_limit when available" }
}
```

`error_kind` is allowlisted to `auth_expired` or `subscription_limit`.
Provider error classification and reset parsing belong in the shim, beside the
provider protocol. Move the existing Rails `subscription_auth_failure?` regex
there rather than adding a sibling quota regex.

`ChaosTriggerClient` must preserve and parse this normalized body on HTTP 429.
Only transport failures or malformed, non-normalized responses should become
“runtime unreachable.”

Rails has one result-classification path:

```ruby
case result.dig(:body, "error_kind")
when "auth_expired"
  surface_auth_expiry!
when "subscription_limit"
  surface_subscription_limit!(result[:body]["subscription_usage"])
end
```

The outcomes remain distinct: an expired credential produces the reconnect
message and marks the connection expired; an exhausted valid subscription
produces the limit/reset message and leaves the connection connected.

### Message behavior

Web conversation:

```text
_Grok's subscription limit has been reached. It should reset at 12:32 AM._
```

Telegram:

```text
Grok's subscription limit has been reached. It should reset at 12:32 AM.
```

`User` already delegates `timezone` to `Profile`; format the reset in that time
zone. If it is absent, include `UTC` explicitly. If no reset is known, say
“Please try again later” rather than inventing a duration.

One explicit human request may produce one limit message. Do not add global
notice deduplication yet.

---

## Settings UI

Extend `AgentProviderSubscriptionPanel.svelte` beneath the connected-account
copy:

- load usage once when a connected subscription panel becomes visible;
- show one compact row per relevant window;
- wording: `72% left · resets in 2h 14m`;
- exhausted rows use the existing destructive/amber styling;
- `unknown` reads `Usage temporarily unavailable`;
- include a small manual Refresh action;
- do not continuously poll;
- do not add graphs, history, pace projections, notifications, or a separate
  usage dashboard.

For providers with several pools:

- Claude may show session, weekly, and model-scoped weekly rows;
- Antigravity may show Gemini and Claude/GPT session/weekly rows;
- OpenAI may show session, weekly, and named model-specific rows;
- Grok initially shows its authoritative subscription credit window.

The runtime marks which rows block the resident's selected model. The settings
panel may display additional informative rows, but only blocking rows affect
request gating.

---

## Security invariants

Test these rather than merely intending them:

1. `/auth/usage` requires the same bearer token as `/trigger`.
2. No access token, refresh token, cookie, authorization header, account id, raw
   provider response, or credential-file fragment appears in:
   - the runtime JSON response;
   - shim logs;
   - Rails logs;
   - `provider_connections`;
   - audit logs;
   - `AgentRuntimeInteraction`.
3. Rails accepts only the normalized allowlist.
4. CodexBar and Chaos probe failures return bounded diagnostics without raw
   stdout/stderr.
5. Usage probes never fall back from a subscription account to an API key.
6. Usage probes never initiate login, open a browser, display a device code, or
   create a second provider credential store.
7. `status: unknown` never blocks a human request.
8. An expired/reset cached limit cannot block indefinitely.
9. Runtime failures expose only normalized `error_kind` values and allowlisted
   snapshot fields, never raw provider output.

---

## Tests

### Runtime/shim

Use fake `chaos`, `codexbar`, `claude`, and `agy` executables plus checked-in
sanitized JSON fixtures:

- normalizes Grok exhausted + reset;
- normalizes OpenAI five-hour/weekly/additional windows;
- normalizes Claude session/weekly/model-scoped windows;
- normalizes all four Antigravity pools;
- marks only model-relevant windows as blocking;
- cache hit avoids a second subprocess;
- concurrent refreshes share one subprocess;
- timeout/malformed JSON/oversized output → `unknown`;
- cache crossing `resets_at` stops blocking;
- bearer auth enforced;
- response and logs contain no fixture secrets;
- API-key triggers bypass subscription usage probes;
- a limited `/trigger` returns 429 without invoking Chaos;
- an unknown snapshot fails open and invokes Chaos;
- provider limit failures become `error_kind: subscription_limit`;
- expired-auth failures become `error_kind: auth_expired`.

### Rails

- usage controller authorization and normalized pass-through;
- `AgentSubscriptionUsage` available/limited/unknown behavior;
- `AgentSubscriptionUsage.new(hash)` performs no transport;
- limited web result creates the assistant system message;
- limited Telegram result sends the Telegram notice;
- a refused trigger still records its `AgentRuntimeInteraction`;
- `ChaosTriggerClient` preserves the normalized body on HTTP 429;
- one `error_kind` case handles gate and post-launch failures;
- the Rails `subscription_auth_failure?` regex is removed;
- auth expiry remains distinct and still marks the connection expired;
- background trigger skips while limited without posting into a conversation.

### Frontend

- connected card renders usage windows and reset copy;
- exhausted/unknown states;
- manual refresh;
- API-key and disconnected agents make no usage request.

### Live acceptance

Run once per provider against a non-production conversation:

1. **Grok:** use an actually exhausted subscription; prove no Chaos turn starts
   and the human receives the reset message.
2. **Grok after reset:** refresh, prove the request proceeds.
3. **Claude:** compare session/weekly values and reset times with Claude Code's
   own `/usage` display.
4. **Gemini:** compare all returned pools with Antigravity's quota summary.
5. **OpenAI:** compare session/weekly windows with the account usage surface.
6. Replace the runtime container and prove credentials remain connected and
   usage still reads from the private volumes.

---

## Implementation order

1. Add and verify `chaos accounts usage --json` for xAI first, against the
   currently exhausted Grok subscription.
2. Add the runtime normalized contract, cache, `/trigger` gate, and Grok probe.
3. Normalize `auth_expired` and `subscription_limit` in the shim; replace the
   Rails auth regex with one `error_kind` result case and add the Grok message.
4. Add the settings-only usage resource and settings-panel rows.
5. Add OpenAI through the same Chaos command.
6. Pin the verified CodexBar Linux CLI release and add Claude and Antigravity
   probes.
7. Run authenticated container acceptance and the four-provider walkthrough.

This order puts the current user-visible failure first while preserving the
provider-independent seam from the beginning.

---

## Non-goals

- No credential storage or refresh in Rails.
- No browser-cookie transfer from Daniel's Mac to a resident.
- No second Grok/OpenAI login ceremony.
- No quota history, charts, pace prediction, cost accounting, alerts, or
  cross-agent aggregation.
- No automatic model/provider fallback when a subscription is exhausted.
- No persisted cooldown state in this iteration.
- No attempt to infer raw “tokens remaining” when the provider exposes only a
  percentage.
- No changes for API-key billing; this feature applies only to connected
  subscription mode.

---

## Review decisions accepted

1. Gate subscription usage inside `/trigger`, not through Rails preflights.
2. Use `error_kind` as the runtime-to-Rails failure vocabulary and retire the
   existing Rails auth regex.
3. Keep transport in `AgentProviderAuthClient`; make
   `AgentSubscriptionUsage.new(hash)` a pure value object.
4. Fail open on `unknown` for every provider.
5. Keep the process-local cache as the only cooldown in this iteration.
6. Show all informative UI rows and use `blocking` only for the turn decision.
7. Keep `source`, `observed_at`, and `blocking` as the complete provenance set.
8. Use only `remaining_percent` in the normalized contract.
