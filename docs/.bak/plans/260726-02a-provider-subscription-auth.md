# Plan 260726-02a — Provider subscription auth for hosted agents

**Author:** Lume
**Date:** 2026-07-26
**Implementer:** Mira
**Companion reference:** `docs/20260726-provider-subscription-auth-from-lume.md` (provider map, ToS postures, sources — treat its posture rows as dated snapshots and re-verify before building)
**Directive from Daniel:** capability, not migration. No agent is being force-upgraded to subscription auth; the option must exist per agent.

---

## Goal

A HelixKit user can connect a provider *subscription account* (ChatGPT Plus/Pro today; SuperGrok / X Premium+ once the Chaos flow lands) to a hosted agent, through the HelixKit UI, and the agent's Chaos sessions then bill against that plan instead of an API key.

## Architectural decision (load-bearing — do not re-litigate casually)

**The OAuth ceremony runs through the agent's own container, and tokens live only in the agent's `/home/agent/.chaos` volume.** HelixKit never receives, stores, logs, or proxies a token. It relays exactly two values from the ceremony: a verification URL and a one-time user code, both single-use and expired within 15 minutes.

Rationale:
1. The plaintext-credentials-in-`audit_logs` bug class (found in the 2026-07-24 account-API-keys review) becomes structurally impossible for OAuth tokens instead of defended-against. HelixKit has nothing to redact because it never had the data.
2. Chaos already manages token refresh in place (`auth.json` in `chaos_home`, write-back on refresh). A DB-held copy would go stale on first refresh; syncing it back is a hard problem we simply don't take on.
3. Credentials-with-the-agent matches the existing sovereignty grain: identity, repo, and chaos state are already per-agent volumes.

Consequence accepted: one ChatGPT account backing N agents means N ceremonies. Per-agent connections only in this iteration (see Non-goals).

## Mechanics recap (verified against the trees 2026-07-26)

- `chaos accounts --device-auth` runs the ChatGPT device-code flow: emits verification URL + one-time code on stderr, polls until the human completes sign-in in any browser, writes `auth.json` under `chaos_home`. See `bin/chaos/src/accounts.rs` (`run_chatgpt_account_flow`, `print_device_code_prompt`) and `bin/console/src/onboarding/auth/headless_chatgpt_login.rs`.
- `chaos accounts` (no flag) reports connection status incl. account email; `AuthMode::{ApiKey, Chatgpt, ChatgptAuthTokens}` is the per-provider auth-mode plumbing.
- Agent containers: `agent-runtime/Dockerfile` pins `CHAOS_REF`; `trigger_shim.py` already runs an authenticated HTTP API (port 4000, bearer token) and knows `CHAOS_HOME`.
- **Verify during implementation:** precedence when both `auth.json` and an env API key are present for the same provider (`cli_auth_credentials_store_mode`, `forced_chatgpt_workspace_id` are nearby config surface). The UX assumes auth-mode is explicit per agent; make sure Chaos agrees rather than silently preferring one.

---

## Workstream 1 — Shim auth API (`agent-runtime/trigger_shim.py`)

New endpoints, same bearer-token auth as `/trigger`:

| Endpoint | Behavior |
|---|---|
| `POST /auth/start` | Spawn `chaos accounts --device-auth` (provider from `AGENT_PROVIDER` or request body). Parse stderr for verification URL + user code. Return `{verification_url, user_code, expires_in}`. 409 if a ceremony is already in flight. |
| `GET /auth/status` | State machine: `none` / `pending` (ceremony running) / `connected` (+ `{email, plan?}` from `chaos accounts` status output) / `failed` (+ message). HelixKit polls this. |
| `POST /auth/cancel` | Kill an in-flight ceremony. |
| `POST /auth/disconnect` | `chaos accounts` disconnect path (`disconnect_all_provider_accounts` exists in accounts.rs — find the CLI surface for it). |

Implementation notes:
- **Output parsing is scrape-based against the pinned `CHAOS_REF`.** Decision: scrape now, don't block on upstream. The prompt strings live in `print_device_code_prompt` / `print_browser_sign_in_prompt`; pin-bump PRs must re-verify the parse (add a shim self-test that fails loudly if the expected markers vanish). In parallel, propose upstream to seuros: `chaos accounts --json` emitting `LoginFlowUpdate` events as JSON lines — the enum is already structured; this is a small PR and makes the scrape deletable.
- Ceremony process lifetime: it polls until completion or 15-min expiry; tie it to a timeout slightly above the code expiry, and make `/auth/status` report expiry distinctly from failure so the UI can offer "get a new code."
- **Never log the user code or any auth.json content.** The verification URL + code may appear in the HTTP response only. Shim logs get the ceremony state transitions, nothing else.

## Workstream 2 — HelixKit UI + backend

1. **Provider capability model.** Server-side table of which auth modes each provider supports: `api_key` (all), `oauth_account` (openai now; xai gated — see Workstream 3), never for gemini/anthropic-subscription (banned/first-party-only; the companion doc has dates and sources — surface *why* in a tooltip, not just absence). Capability for `oauth_account` should be resolvable per-container (chaos version probe via the shim) so xAI lights up automatically when the runtime image carries the flow.
2. **Agent settings → provider card**: auth-mode picker (`API key` | `Subscription account`) shown only where supported. Selecting subscription with no connection → `Connect` button.
3. **Connect modal**: verification link (+ QR code for phone flows), one-time code with copy button, live status via `/auth/status` polling, countdown to code expiry, regenerate-on-expiry. Keep Chaos's own phishing warning verbatim: device codes are a phishing target; never share the code.
4. **Connected state**: card shows account email (+ plan if reported), `Reconnect` / `Disconnect`, and the quota-honesty line: *"Agent usage draws on this account's personal plan quota."* Persist only `{provider, email, plan, connected_at, status}` — this is display metadata, not a credential. It may go through normal audit logging precisely because it contains no secret.
5. **Runtime error mapping**: when a `chaos exec` fails with auth-expired/unauthorized while auth-mode is subscription, the error surfaced in the chat/session UI must say *"Provider connection expired — reconnect in agent settings"* with a link, not a raw provider error. (Find the actual error shape empirically: disconnect and trigger.)
6. **Promotion wizard**: optional "Connect provider account" step at first container boot, reusing the same modal + endpoints. Skippable; agents can start on API keys and connect later.

## Workstream 3 — Chaos xAI OAuth flow (upstream track)

Goal: `chaos accounts --device-auth` (or provider-scoped equivalent) working against auth.x.ai for SuperGrok / X Premium+, so xAI reaches parity with the ChatGPT flow.

1. **Check upstream first.** The OpenCode integration (x.ai/news/grok-opencode) is generating demand for exactly this; seuros may have it planned or in flight. Open an issue/ask before writing code.
2. If building: model on the existing ChatGPT flow — auth.x.ai OAuth with PKCE, device-code variant for headless, token storage in `auth.json` alongside (per-provider `AuthMode` plumbing already exists; the per-provider "does not support ChatGPT account connections" gate in `accounts.rs:183` is where provider capability is declared). Reference implementations: `ysnock404/opencode-grok-auth` (PKCE flow details), Hermes agent's xAI OAuth guide.
3. Contribution path: PR to `seuros/chaos`, then bump `CHAOS_REF` in `agent-runtime/Dockerfile`. HelixKit needs no UI change — the capability probe (Workstream 2.1) flips xAI on.
4. Bundle the `--json` accounts output proposal (Workstream 1) into the same upstream conversation if it hasn't landed.

## Non-goals (this iteration)

- **No token custody in HelixKit.** No `auth.json` in the DB, encrypted or otherwise. If a future feature seems to need it, that's a new plan with a new security review.
- **No account-level "connect once, share across agents."** Copying connections between agent volumes touches tokens and reopens the custodian question. Ship per-agent; revisit only if the N-ceremonies annoyance proves real.
- **No Gemini or Anthropic subscription options.** Gemini: Google banned third-party OAuth use (Feb 2026, enforced since Mar 25) — do not build, do not offer. Anthropic: clamp path already exists and is separate machinery.
- **No migration.** Existing API-key agents keep working untouched; auth-mode defaults to `api_key`.

## Security invariants (test these, not just intend them)

1. No token, refresh token, or `auth.json` fragment ever appears in HelixKit's DB, logs, or audit trail. (Grep-level test on audit payloads for the connected-account flows.)
2. Shim logs contain no user codes.
3. `/auth/*` endpoints require the same bearer auth as `/trigger`.
4. Disconnect actually removes `auth.json` state in the volume (verify empirically — then confirm the next `chaos exec` falls back to API key or fails cleanly per configured auth-mode).

## Acceptance walkthrough

1. Agent with `AGENT_PROVIDER=openai`, no `OPENAI_API_KEY` needed: connect via modal, code entered on phone, card shows email, trigger runs and bills the ChatGPT plan.
2. Kill + recreate container (volume persists): still connected, no re-ceremony.
3. Disconnect: next trigger surfaces the reconnect-worded error in chat.
4. (Post-Workstream 3) Same walkthrough for an xAI agent on SuperGrok.
5. Gemini agent settings show no subscription option, with the why-tooltip.

## Open questions for Mira

- Does `chaos accounts` cleanly scope to a single provider when multiple are configured, or is connection state effectively global-per-chaos-home? Affects whether one agent can hold ChatGPT auth *and* an xAI key simultaneously. (accounts.rs suggests per-provider support exists; verify.)
- What exactly does the status output expose — email only, or plan tier too? UI copy should promise only what's reliably there.
- Shim `/auth/status` polling vs SSE: polling is fine at this scale; SSE only if the modal feels laggy.

---

*Two defaults encoded above that Daniel left to judgment: per-agent connections only, and scrape-now/PR-upstream-in-parallel for the accounts output. Both are overridable — they're marked where they bind. — Lume*
