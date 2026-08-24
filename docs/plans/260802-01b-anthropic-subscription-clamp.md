# Plan 260802-01b — Anthropic subscription auth via Chaos clamp (rev. after Mira's review)

**Author:** Lume
**Date:** 2026-08-02 (01a same day; this revision metabolizes `260802-01a-anthropic-subscription-clamp-feedback-for-lume.md` — all six findings verified against the trees and accepted)
**Implementer:** Mira (HelixKit + shim), upstream track needs seuros
**Companion references:** `docs/plans/260726-02a-provider-subscription-auth.md` (the OpenAI/xAI flow this extends), `docs/20260726-provider-subscription-auth-from-lume.md` (provider ToS map)
**Directive from Daniel:** capability, not migration; shared account, not dedicated (2026-08-02).

---

## Goal

A souls.house resident on an Anthropic model can bill its turns to a Claude Max subscription instead of API tokens, using Chaos's clamp module (Claude Code as headless subprocess transport), connected through the same in-container OAuth ceremony shape as the OpenAI/xAI flows.

## Architectural decisions (load-bearing — do not re-litigate casually)

1. **Shared account, accepted deliberately (Daniel, 2026-08-02).** The resident connects to the operator's own Max account — current utilization (~42%/week) leaves headroom; a dedicated per-resident subscription was judged too expensive. On the record, what this accepts: the resident, the operator's interactive Claude Code use, and Lume draw from the same 5-hour windows and weekly buckets; a cap-hit takes them all down together. Required mitigations: consumption visibility (Workstream 4.4) and durable cap-hit cooldown (Workstream 5). **Revisit trigger:** the first week the account hits a weekly cap, the dedicated-account option returns — a re-ceremony, not a rebuild.
2. **Ceremony through the agent's container; credentials only in the agent's volumes.** Verified 2026-08-02: in containers Claude Code's login shows a paste-code when the browser can't reach the callback server, and `claude auth login` reads that code from **stdin**. The shim drives it like the ChatGPT device flow with the direction flipped: login URL travels outbound, one-time code inbound (browser → HelixKit → shim → subprocess stdin). HelixKit relays the short-lived single-use code in transit only — never persisted, never logged. Credentials are written by Claude Code itself into the **dedicated state volume** (Workstream 1) and refresh in place. HelixKit never sees a token.
3. **One semantic auth-mode value, translated at the shim boundary (per Mira's review, finding 3).** HelixKit's persisted mode stays `oauth_account` — its meaning is "bills a provider subscription account," and everything downstream (interaction validation, `subscription_based?` billing classification, connection recording) already keys on it correctly. The *transport* difference — device-flow for openai/xai, clamp for anthropic — is runtime mechanics and lives in the shim, branched on provider. No new persisted enum value; no product-state/runtime-state split to keep coherent.
4. **Clamp (Chaos stays the harness), not Claude-Code-as-harness.** Clamp drives the official `claude` binary over the stream-json control protocol — the sanctioned surface — while Chaos keeps owning tools, permissions, sessions, telemetry. Claude-Code-as-harness stays documented fallback only.
5. **Optimization, never dependency.** Anthropic flipped policy on programmatic subscription use three times in 2026 (Feb OAuth restriction → Apr 4 third-party ban → May 13 credit-pool announcement → Jun 15 cancellation). Fallback to `api_key` must always be a settings change plus a session roll — no other coupling anywhere.

## Verified mechanics (dated 2026-08-01/02 — re-verify posture before building)

- **Clamp module** (`sys/modules/clamp/`): real, ~2,100 lines + tests. Spawns `claude` with stream-json in/out, `--setting-sources ""`, MCP session bridge back into Chaos, optional wiretap proxy.
- **Gap 1 — headless enable:** clamp is toggled by IPC op `SetClamped`; only the interactive TUI sends it. `chaos exec` cannot enable it. Kernel plumbing (`ModelClient::set_clamped`) exists.
- **Gap 2 — telemetry (Mira, finding 2, verified):** the clamped streaming path completes with `token_usage: None` (`streaming.rs:843-857`) and clamp's `Result` message doesn't deserialize Claude Code's usage fields (`protocol.rs:120-128`). Clamped turns reach HelixKit with unknown usage; `AgentRuntimeInteraction` only trusts versioned invocation-local usage.
- **Auth:** primary path `claude auth login` in-container (stdin code, credentials at `CLAUDE_CONFIG_DIR`, auto-refresh, CLI warns 3 days before login expiry). Fallback `claude setup-token` (1-year env token). Both bill the subscription.
- **Gotcha 1 — bare mode:** bare mode skips credential discovery. `ClampConfig.bare_mode` must stay false for subscription agents. Assert.
- **Gotcha 2 — precedence:** a present `ANTHROPIC_API_KEY` always wins in `-p` mode. Shim env shaping must pop it (existing `_oauth_account_env` pattern).
- **Limits:** Max 20x ≈ 240–480 Sonnet-hrs/week, ~24–40 Opus-hrs/week, separate buckets, 5-hour rolling session caps. Opus is the tight dimension. Exact limit-hit error shape in `-p`/`chaos exec --json` is undocumented — establish empirically; Workstreams 3.4 and 5 consume the answer.

## Workstream 0 — Upstream chaos (talk to seuros first)

1. **Headless clamp enable:** config key preferred (e.g. per-profile `clamp = true`) over a CLI flag — survives `resume`, and the shim already passes `-c` overrides. Reduces to sending `SetClamped { enabled: true }` at session start. Verify clamp × persistent sessions: the resume path must re-establish the clamped transport.
2. **Clamp usage telemetry (new, from review):** preserve Claude Code's result usage fields in `chaos-clamp`'s `Result` message; translate into Chaos `TokenUsage`/`TokenCount` events with invocation-local scope; end-to-end `chaos exec --json` test proving clamped usage reaches stdout JSONL. Workstream 4.4 is blocked on this item.
3. Verify clamp inherits `CLAUDE_CODE_OAUTH_TOKEN`/`CLAUDE_CONFIG_DIR` from the chaos process env (shim sets `shell_environment_policy.inherit="all"`).
4. Bundle the still-open `chaos accounts --json` proposal from 260726-02a if that conversation is live.

## Workstream 1 — Per-agent state volume (new, from review finding 1)

The hosted runtime mounts only `identity`, `.chaos`, `repo`, `work` — the 01a credentials path would have died with the container layer.

- New Docker volume per agent mounted at `/home/agent/state` (e.g. `agent-state-<uuid>`): creation with the other volumes in `sandbox.rb`, deletion in the same lifecycle that removes them, entrypoint `mkdir -p` + ownership for `/home/agent/state/claude`.
- Status/diagnostic reporting alongside the existing volume checks.
- Recreation/backup expectations documented with the other volumes.
- **Boundary test:** no HelixKit-facing filesystem endpoint (workspace browsing, file APIs, anything that reads agent mounts) can reach `/home/agent/state`. Explicitly do *not* put credentials in identity, repo, or the chaos volume — the boundary claim must be checked, not architectural folklore.

## Workstream 2 — Runtime image (`agent-runtime/Dockerfile`)

- Install Claude Code, **pinned version**, recorded next to `CHAOS_REF` with the same bump-discipline comment (the ceremony scrape in Workstream 3 is pinned against it).
- Build-time smoke test: `claude --version` only. The authenticated `claude -p` check moves to a **runtime diagnostic** (shim endpoint or manual harness) reporting success/failure and non-secret metadata only — build-time credentials would always be absent in ordinary builds and a secret-handling risk otherwise (review finding 6).

## Workstream 3 — Shim (`agent-runtime/trigger_shim.py`)

1. `auth_mode` stays `api_key | oauth_account` on the wire (decision 3). For `provider == "anthropic"` + `oauth_account`, the shim's transport branch is clamp, not device-flow.
2. **Ceremony endpoints — same `/auth/*` surface, anthropic branch:** `/auth/start` spawns `claude auth login` with `CLAUDE_CONFIG_DIR=/home/agent/state/claude`, scrapes the OAuth URL, returns `{verification_url}`. New `POST /auth/code`: writes the browser-shown code to the subprocess stdin; never logged. `/auth/status` gains `awaiting_code`. Scrape is version-pinned with a self-test that fails loudly when the output markers vanish (same discipline as the chaos accounts scrape).
3. Env shaping for anthropic subscription turns: pop `ANTHROPIC_API_KEY`, set `CLAUDE_CONFIG_DIR`. Add anthropic to `PROVIDER_API_KEY_ENV`.
4. Pass the clamp enable (per Workstream 0.1) on those turns.
5. **Disconnect — Option A, matching the existing lifecycle (review finding 4):** `/auth/disconnect` deletes the credentials directory **and rolls the persistent Chaos session so the live clamp subprocess terminates** — deleting `.credentials.json` alone does not stop a subprocess with credentials already in memory. HelixKit's existing `clear_provider_connection!` flips the agent to `api_key`; the next trigger succeeds on API billing when a key exists, or surfaces the missing-key error if not. Test: connect → complete a turn → disconnect → prove the next trigger does *not* run clamped.
6. Session roll on auth-mode change already exists (`roll_decision`); add a test for `api_key ↔ oauth_account` on anthropic.

## Workstream 4 — HelixKit UI + backend

1. Capability: add `anthropic` to `Agent::OAUTH_ACCOUNT_PROVIDERS`, gated on the runtime probe (shim reports chaos-with-headless-clamp + claude binary). Controller guard (`provider_subscriptions_controller`) admits anthropic; `record_provider_connection!` is already correct under decision 3.
2. Connect modal: reuse the 260726 component with the flow direction flipped — sign-in link out, *"enter the code the browser shows you"* field posting through to `/auth/code`. Connected card: account email, login-expiry warning when the shim reports one. Quota-honesty line: *"Agent usage draws on this account's personal plan quota."*
3. Runtime error mapping: limit-hit → *"Subscription limit reached — resumes ~{time}"* when parseable, else generic cooldown + settings link. Auth-expired → *"Subscription login expired — reconnect in agent settings."* Shapes from the Workstream 0/3 empirical test.
4. **Consumption visibility (required by decision 1; blocked on Workstream 0.2):** surface the resident's rolling daily/weekly token usage on the agent card, **labeled as resident-local activity — explicitly not account quota.** Resident-local counts omit the operator's interactive use and every other consumer; unless Claude Code exposes authoritative account-limit state (probe for it; display separately if so), the card must say plainly that total shared-account headroom is not directly measurable. Until 0.2 lands, clamped turns show "usage unknown" honestly rather than zero.
5. **Cross-layer test coverage (review finding 3):** conversation, wake, Telegram, orientation, and memory-aggregation trigger paths all send and record the anthropic + `oauth_account` combination correctly; interaction validation passes; billing classification reports subscription-based.

## Workstream 5 — Cap-hit cooldown (new, from review finding 5)

Coordination target corrected: `docs/plans/260801-01-wake-notices.md` (the 01a citation collided with the same-numbered telegram-inbound-media plan).

- **Durable state:** `subscription_limited_until` timestamp per agent (or a `provider_cooldowns` map if a second provider ever needs it — don't build the map speculatively). Set when a turn fails with a parseable limit reset time; when no reset time is parseable, default to 60 minutes, doubling per consecutive limit failure, capped at 5 hours (the session-window period).
- **Scope:** suspends *all background trigger kinds* — scheduled wakes, orientation, memory aggregation, Telegram-initiated background turns. **Manual conversation triggers pass through:** a human is present to see the limit error surface, and they may be testing whether the cooldown has lifted.
- **Never touches `scheduled_wakes_enabled`** — that is a user preference, not a provider condition.
- **Standing notice:** one per cooldown window (dedup on the cooldown record, not per skipped wake), carrying the resume time when known; expires when the cooldown clears.
- **Clearing:** expiry of the timestamp, a successful subscription turn, reconnect, or switching the agent to `api_key`.
- **Scheduler test:** simulate limit-hit → advance through a due wake slot → prove no trigger fires and no second failed turn is recorded → advance past reset → prove wakes resume.

## Non-goals

- No token custody in HelixKit (decision 2). URL out, one-time code in, transit only.
- No dedicated per-resident accounts this iteration (decision 1 — revisit trigger documented).
- No new persisted auth-mode value (decision 3).
- No Claude-Code-as-harness build (fallback documented, not built).
- No Gemini change. No migration; `api_key` stays the default.

## Security invariants (test, don't intend)

1. No credential, refresh token, or `.credentials.json` fragment in HelixKit DB, logs, audit trail, or shim logs/telemetry — grep-level tests. The one-time login code exists in exactly one place, the `/auth/code` request body in flight; assert absence from request logs and audit payloads.
2. Exec env for anthropic subscription turns has `CLAUDE_CONFIG_DIR` set and no `ANTHROPIC_API_KEY` — shim test.
3. Clamp config for those turns has `bare_mode == false` — assert where built.
4. `/home/agent/state` unreachable from every HelixKit-facing filesystem endpoint — the Workstream 1 boundary test. `.credentials.json` 0600.
5. Disconnect kills the live clamp subprocess — the Workstream 3.5 test.

## Acceptance walkthrough

1. Connect via modal: sign-in link, code pasted back, `/auth/status` runs `awaiting_code → connected`; next trigger rolls the session, runs clamped, bills the plan (verify: zero API-key usage on the Anthropic console for the period).
2. **Container replacement, not just restart:** recreate the container from image; the state volume preserves the login; no re-ceremony.
3. **Disconnect with a live subprocess:** connect, complete a turn, disconnect → agent is on `api_key`, next trigger succeeds via API billing (or surfaces missing-key), and provably does not run clamped.
4. **Telemetry provenance:** complete a clamped turn; `chaos exec --json` output, shim response telemetry, and `AgentRuntimeInteraction` agree on whether usage is known. (Pre-0.2: all three honestly report unknown.)
5. **No false quota claim:** UI distinguishes resident-local activity from shared-account remaining quota.
6. **Cooldown scheduler:** simulate limit-hit; advance through a wake slot — no request sent; advance past reset — wakes resume; exactly one standing notice for the window.
7. **Auth-mode persistence:** anthropic + `oauth_account` accepted and recorded consistently across conversation, wake, Telegram, orientation, and memory-aggregation paths.
8. An agent whose runtime probe reports no clamp/claude sees the anthropic subscription option greyed with the why-tooltip.

## Open questions for Mira / upstream

- Flag vs config key for headless clamp enable — whichever seuros prefers; config-key recommended for resume-safety.
- Does clamp's model naming match `Chat::MODELS` ids, or does the Claude Code init model list need a mapping? (Clamp caches the init list — check early.)
- Limit-hit and auth-expired shapes in `chaos exec --json` when the clamped subprocess fails — feeds 4.3 and 5; establish in the Workstream 0 test rig.
- Does Claude Code expose any account-level quota/limit state a diagnostic could probe (for 4.4's separate display)? If not, resident-local labeling stands alone.

---

*Priced context for the decision record: Max 5x $100/mo, Max 20x $200/mo; an active resident on API billing plausibly exceeds either within weeks — why the shared account is worth trying, and why a dedicated one stays affordable if caps bind. The 42% behind decision 1 is pre-resident; Workstream 4.4 exists so the post-resident number is a checked fact — with the review's correction that resident-local activity ≠ account headroom, and the honest gap labeled until upstream telemetry lands. The 2026 three-flip policy history is why decision 5 is a decision and not a remark. — Lume*
