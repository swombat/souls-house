# Review: 95f0f95 "Add provider subscription authentication" — from Lume

**Reviewer:** Lume
**Date:** 2026-07-26 (late)
**Reviewing:** commit `95f0f95` (Mira's implementation of plan `260726-02a`), HelixKit side only per Daniel — the Chaos xAI work is explicitly out of scope, as is the in-flight uncommitted delta (panel extraction into `AgentProviderSubscriptionPanel.svelte` + agent edit page wiring — direction looks right, not reviewed).

---

## Verdict

Good implementation — the load-bearing invariant genuinely held. One finding I'd fix before this deploys to agents with live persistent sessions (silent continuity loss), one behavioral gap worth closing (abandoned ceremony bricks the provider), and smaller polish items. Nothing here is architectural; the architecture came out right.

**What the plan asked for and got, verified:**
- **No token custody.** `record_provider_connection!` slices to `email/plan/status/connected_at`; the shim's `_public_auth_state` strips `verification_url`/`user_code` from every status response — the code is served exactly once, in the `/auth/start` response, and never again. Tests assert the code is absent from `provider_connections` *and* from audit-log payloads, and that status parsing returns exactly `[email, provider, status]`. This is the invariant done properly — tested, not intended.
- Bearer auth on all `/auth/*` endpoints (tested).
- Auth-mode change rolls persistent sessions (`auth-mode-changed`, tested).
- OAuth exec strips the metered API key from env so chaos can't silently fall back to pay-per-token (tested) — a case the plan didn't even ask for.
- Expired-connection error surfaced in chat with a reconnect link; connection marked `expired`.
- New `zai`/`minimax`/account key columns are `encrypts`-ed.
- The precedence open-question answered structurally: separate `CHAOS_HOME`s per auth mode, so `auth.json` and API-key runs can't contaminate each other. Right idea — but see finding 1 for which home got which mode.

---

## 1. HIGH — existing persistent sessions silently lose continuity on first trigger after deploy

`run_chaos` now redirects **api_key mode** (the default, i.e. every existing agent) to a new home: `CHAOS_HOME/api-key-runtime`. But every pre-existing session's Chaos state lives in the *original* `CHAOS_HOME`, and `SIDECAR_SCHEMA_VERSION` was not bumped, so old records don't roll cleanly: `record.get("auth_mode", "api_key") == "api_key"` → no roll → resume attempted against a home where the process id doesn't exist → resume fails → `resume-failed` fallback starts a fresh session.

It self-heals, but the healing *is* the damage: **every hosted agent's persistent Chaos session context is discarded on the first trigger after this deploys**, logged only as a resume failure. For agents where session continuity is identity-adjacent (Claude/Purple Moon), that's a real loss, and it will look like a mysterious mass amnesia event rather than a chosen migration.

**Suggested fix — invert the home split.** Let `api_key` mode keep the *default* `CHAOS_HOME` (preserving all existing session state), and give **oauth mode** the subdir (`CHAOS_HOME/oauth-runtime`). Isolation is identical; continuity is preserved; oauth sessions are all new anyway so nothing is lost on that side. Requires the ceremony to write `auth.json` into the oauth home — i.e. `auth_start`/`auth_status`/`auth_disconnect`/`_provider_account_status` must set `env["CHAOS_HOME"]` to the oauth home too (currently they use the default env, which is consistent with the *current* split but must move with it).

If the split stays as-is instead: bump `SIDECAR_SCHEMA_VERSION` or add an explicit migration/roll reason so the continuity loss is deliberate, logged as such, and happens once — not disguised as resume failures.

Second-order check either way: whatever home api-key runs use must contain any `config.toml` a custom provider needs (bundled providers — zai/minimax/xai — need none; a future Kimi block would). A home-split means user-level chaos config exists in one home and not the other.

## 2. MEDIUM — abandoned ceremony leaves the agent in a broken auth mode

`ProviderSubscriptionsController#create` flips the agent to `oauth_account` **when the ceremony starts**, not when it completes (and the controller test at "start relays the one-time code" asserts this, so it's intentional — I think it's the wrong intention). If the user closes the modal, lets the code expire, or the ceremony fails: mode stays `oauth_account`, there's no `auth.json`, and exec strips the API key from env → every trigger fails. Worse, the failure text for "no credentials at all" (likely chaos's env-var/connection error) won't match the `unauthori[sz]ed|…expired|401` regex in `subscription_auth_failure?`, so the user gets a generic failure with no reconnect hint.

Fix options, either is fine:
- Flip mode only on confirmed connection — `record_provider_connection!` already sets `oauth_account`, so the flip in `create` is both premature *and* redundant; delete it and update the test.
- Or keep it and auto-revert to `api_key` on cancel/expiry/failure.

Also worth one more alternation in the regex for the no-credentials case (empirically capture what chaos actually emits when oauth mode has no `auth.json` — acceptance walkthrough step 3 will surface it).

## 3. MEDIUM (small fix) — "expired" status is overwritten by "failed"

`auth_status`'s expiry branch terminates the process and sets state `expired`, but leaves `_auth_process` set. The monitor thread then observes the nonzero exit and — since `_auth_process is process` still holds — overwrites state with `failed` / "Provider connection was not completed." The UI's "Get a new code" affordance keys off a state that survives for roughly one poll interval. One-line fix: clear `_auth_process = None` in the expiry branch so the monitor's guard skips the overwrite.

## 4. LOW — capability gating is env-declared, not probed, and the UI trusts the static constant

`/auth/capabilities` reports whatever `CHAOS_OAUTH_ACCOUNT_PROVIDERS` says (default `openai`) without probing the binary, and the Rails side doesn't call it at all — `subscription_agents` uses the static `Agent::OAUTH_ACCOUNT_PROVIDERS` (`openai xai`). Net effect: an xai agent shows a connect affordance today; pressing it gets the shim's 422 (which the panel does surface as an error). Fine for now, but the plan's "xai lights up automatically when the runtime supports it" isn't wired — lighting up xai will take a runtime-env change *and* the UI will have offered the button the whole time. When Workstream 3 lands, either wire the capabilities endpoint into what the UI offers, or keep the constant and accept the 422 as the gate. Also note `_provider_account_status` matches the literal `"ChatGPT account"` — whatever status line the future chaos xai flow prints, this parser and `_line_names_provider` need revisiting together.

## 5. Notes (no action required)

- `auth_start` waits 10s for the code; on slow starts it returns 502 while the ceremony keeps running, and a retry hits 409. Recoverable via cancel → start; acceptable.
- The scrape self-test the plan asked for exists in mocked form (marker strings tested against fixtures), which protects against accidental parser edits but not against a `CHAOS_REF` bump changing chaos's output. Residual risk rides on the pin; re-verify the parse on every pin bump (a comment near `CHAOS_REF` in the Dockerfile pointing at `_monitor_auth_process` would do it).
- Failure surfacing is wired into the conversation path (`ExternalAgentResponseRequest`) only; wake/telegram/orientation paths pass `auth_mode` but surface nothing — reasonable, they have no chat to post into, but expect expired-auth wake failures to be visible only in logs.
- Did not verify how `zai`/`minimax` account keys reach container env (out of this commit's diff); assumed existing `AI_PROVIDERS` plumbing covers it.

---

## Ranking

| # | Severity | One-line |
|---|---|---|
| 1 | HIGH | Home split orphans all existing persistent sessions — invert it (api_key keeps default home) or make the roll explicit |
| 2 | MEDIUM | Mode flips at ceremony start; abandonment bricks the provider with an unhinted failure |
| 3 | MEDIUM | Expired state overwritten to failed by the monitor thread race |
| 4 | LOW | Capability gating static/env-based; xai affordance shows before runtime support |
| 5 | — | Notes |

The security invariant — the reason the architecture was chosen — held under inspection, and held *in tests*, which is better than held in prose. Findings 1 and 2 are both about lifecycle edges, not about the design. Good work, fast.

— Lume

---

## Fix verification — 2026-07-27, from Lume

Checked the working tree (uncommitted fix set) plus commit `a36eaf5` against the findings:

| # | Status | How |
|---|---|---|
| 1 | **Fixed as suggested** | Split inverted: api_key keeps the default `CHAOS_HOME` (existing sessions preserved), oauth gets `oauth-runtime/`. All four account-command surfaces (`auth_start`, `auth_disconnect`, `_provider_account_status`, exec) route through `_oauth_account_env()`. Test renamed to assert the property by name ("API key runs preserve the original Chaos home"), plus a new test that account commands use the isolated home. |
| 2 | **Fixed** | Premature `use_provider_auth_mode!` deleted from `create`; mode now flips only via `record_provider_connection!` on confirmed connection. Both controller tests updated to assert the new lifecycle. The failure regex also gained no-credentials alternations. |
| 3 | **Fixed** | `_auth_process` cleared before terminate in the expiry branch, with a dedicated regression test simulating the monitor thread racing after expiry ("expired auth ceremony cannot be overwritten"). |
| 4 | **Fixed beyond the ask** | Upstream chaos xAI subscription auth landed; `CHAOS_REF` bumped to `39cacb3` with the re-verify-the-parser comment on the pin. `/auth/capabilities` now exposed through the controller (`?capabilities=true`, tested); env default now `openai,xai`; status parser accepts `xAI account` lines. |
| 5 | Noted | Reconnect link now points at agent hosting settings tab. |

Independently verified against chaos `39cacb3` (fetched the ref): the status line literal (`{provider_name}: xAI account ({email})`) and the device-code marker (`one-time code`) both match the shim's parser.

Two residual crumbs, neither blocking: the new upstream prompt has a variant with a *variable* expiry ("expires in {} minutes") while the shim hardcodes 15 — if the xai flow uses a shorter TTL, the countdown will overpromise; consider parsing the minutes from the line. And the no-credentials regex alternations look speculative — acceptance walkthrough step 3 (disconnect, then trigger) will confirm what chaos actually emits.

All findings closed. — Lume
