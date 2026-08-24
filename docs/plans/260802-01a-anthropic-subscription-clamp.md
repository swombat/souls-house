# Plan 260802-01a — Anthropic subscription auth via Chaos clamp

**Author:** Lume
**Date:** 2026-08-02
**Implementer:** Mira (HelixKit + shim), upstream track needs seuros
**Companion references:** `docs/plans/260726-02a-provider-subscription-auth.md` (the OpenAI/xAI flow this extends), `docs/20260726-provider-subscription-auth-from-lume.md` (provider ToS map — its Anthropic row said "clamp — done"; this plan exists because *done* meant done-in-console, unwired for exec)
**Directive from Daniel:** capability, not migration. Per-agent opt-in; existing API-key agents untouched.

---

## Goal

A souls.house resident on an Anthropic model can bill its turns to a **Claude Max subscription** instead of API tokens, using Chaos's clamp module (Claude Code as headless subprocess transport), connected through the same in-container OAuth ceremony as the OpenAI/xAI flows. For an active resident this replaces potentially hundreds of dollars a month of API spend with plan quota.

## Architectural decisions (load-bearing — do not re-litigate casually)

1. **Shared account, accepted deliberately (Daniel, 2026-08-02).** The resident connects to the operator's own Max account — Daniel's current utilization (~42%/week) leaves headroom, and a dedicated per-resident subscription was judged too expensive. What this accepts, on the record: the resident, the operator's interactive Claude Code use, and Lume now draw from the same 5-hour windows and weekly buckets, and a cap-hit takes them all down together. Mitigations required, not optional: (a) the resident's consumption must be visible (Workstream 3.4), (b) cap-hit must suspend wakes gracefully (Workstream 3.3/3.5). **Revisit trigger:** the first week the account hits a weekly cap, the dedicated-account option comes back on the table — the per-agent auth architecture makes that a re-ceremony, not a rebuild.
2. **Same ceremony shape as OpenAI/xAI: through the agent's container, credentials live only in the agent's volume.** Verified 2026-08-02: in containers, Claude Code's login shows a paste-code when the browser can't reach the local callback server, and `claude auth login` reads that code from **stdin** — no TTY scraping. So the shim can drive it exactly like the ChatGPT device flow, with one asymmetry to name: OpenAI's flow sends a code *outbound* (user types it into the provider's site); Anthropic's sends the login URL outbound and a one-time code *inbound* (browser → HelixKit → shim → subprocess stdin). HelixKit relays that short-lived single-use code in transit and must never persist or log it; the resulting credentials are written by Claude Code itself inside the container (`~/.claude/.credentials.json` under a `CLAUDE_CONFIG_DIR` on the agent volume) and refresh in place — same grain as chaos's `auth.json`. HelixKit never sees a token.
3. **Clamp (Chaos stays the harness), not Claude-Code-as-harness.** Clamp drives the official `claude` binary over the same stream-json control protocol the Agent SDK uses — the sanctioned surface — while Chaos keeps owning tools, permissions, sessions, and telemetry. The alternative (shim shells to `claude -p` directly) is documented as fallback only: it forks the harness codepath and the shim's session model. Build it only if the upstream track stalls hard.
4. **Optimization, never dependency.** Anthropic flipped policy on programmatic subscription use three times in 2026 (Feb OAuth restriction → Apr 4 third-party ban → May 13 credit-pool announcement → Jun 15 cancellation, back to subscription draw). The per-agent auth-mode toggle must always be able to fall back to `api_key` with a settings change and a session roll — no other coupling to subscription auth anywhere.

## Verified mechanics (dated 2026-08-01/02 — re-verify posture before building)

- **Clamp module** (`sys/modules/clamp/` in seuros/chaos): real, ~2,100 lines + tests. Spawns `claude` with `--input-format/--output-format stream-json`, `--setting-sources ""`, routes tool calls back through Chaos via an MCP session bridge, optional wiretap proxy via `ANTHROPIC_BASE_URL`.
- **The gap:** clamp is toggled by IPC op `SetClamped`, and the only sender is the interactive TUI (`console --clamp` / `/clamp`). `chaos exec` — the shim's path — cannot enable it. Kernel plumbing (`ModelClient::set_clamped`) is already there.
- **Auth, two viable paths:** (a) **`claude auth login`** in-container — paste-code flow, code read from stdin, credentials written to `.credentials.json` (0600) under `CLAUDE_CONFIG_DIR`, refreshed in place by Claude Code; logins expire eventually (the CLI warns 3 days out — surface that via `/auth/status`) and renewal is the same ceremony re-run. **This is the primary path** — it matches the OpenAI flow shape. (b) `claude setup-token` → 1-year env token via `CLAUDE_CODE_OAUTH_TOKEN` — keep as documented fallback if the in-container ceremony proves brittle. Both bill the subscription (Pro/Max required).
- **Gotcha 1 — bare mode:** Claude Code's bare mode ignores `CLAUDE_CODE_OAUTH_TOKEN` (and skips setting/credential discovery generally). `ClampConfig.bare_mode` defaults false; it must *stay* false for subscription agents. Assert, don't assume.
- **Gotcha 2 — precedence:** in `-p` mode a present `ANTHROPIC_API_KEY` env var **always wins** over the OAuth token. The shim's existing oauth env shaping (`_oauth_account_env` + `PROVIDER_API_KEY_ENV` pop) already solves this pattern for OpenAI — Anthropic joins it.
- **Limits:** Max 20x ≈ 240–480 Sonnet-hrs/week but only ~24–40 Opus-hrs/week, separate buckets, plus 5-hour rolling session caps. Sonnet residents fit easily; Opus is the tight dimension. Exact `-p` limit-hit error shape (exit code, machine-readable reset time) is undocumented — establish empirically, it feeds the error mapping below.

## Workstream 0 — Upstream: headless clamp enable (talk to seuros first)

Goal: `chaos exec` can start/resume a session clamped. Preferred surface: a config key (e.g. `clamp = true` per profile/provider) over a CLI flag — the shim already passes `-c` overrides, and config survives `resume`. Either way it reduces to sending `SetClamped { enabled: true }` at session start.

- Verify clamp × persistent sessions: the shim's resume path (`chaos exec … resume <process_id>`) must re-establish the clamped transport. If clamp state isn't persisted in the session record, the config-key approach fixes that for free.
- Verify clamp respects `CLAUDE_CODE_OAUTH_TOKEN` from the inherited env (shim sets `shell_environment_policy.inherit="all"`; clamp spawns `claude` from the chaos process env).
- Bundle with the still-open `chaos accounts --json` proposal from 260726-02a if that conversation is live.

## Workstream 1 — Runtime image (`agent-runtime/Dockerfile`)

- Install Claude Code, **pinned version** (native installer or npm; record the pin next to `CHAOS_REF` with the same bump-discipline comment). Image grows; measure, don't guess.
- Smoke test in build: `claude --version` and a `claude -p 'ok'` dry check gated on token presence (skip cleanly when absent — most agents won't have one).

## Workstream 2 — Shim (`agent-runtime/trigger_shim.py`)

1. New `auth_mode` value: `subscription` (valid only with `provider == "anthropic"`; 400 otherwise). Existing validation currently allows `api_key | oauth_account` — extend.
2. **Ceremony endpoints — reuse the existing `/auth/*` machinery:** `/auth/start` for anthropic spawns `claude auth login` (with `CLAUDE_CONFIG_DIR` pointed at the agent volume), scrapes the OAuth URL from its output, returns `{verification_url}` (no user_code in this direction — the asymmetry from decision 2). New endpoint `POST /auth/code`: accepts the code the human got from the browser, writes it to the subprocess's stdin, never logs it. `/auth/status` gains `awaiting_code` between the two. Scrape is version-pinned like the chaos accounts scrape — add the same self-test that fails loudly if the expected output markers vanish, and pin the Claude Code version in the image accordingly.
3. Env shaping for `subscription`: pop `ANTHROPIC_API_KEY`, set `CLAUDE_CONFIG_DIR` to the agent-volume credentials dir. Reuse the `_oauth_account_env` pattern; add `anthropic` to `PROVIDER_API_KEY_ENV`.
4. Pass the clamp enable (config key or flag, per Workstream 0 outcome) when `auth_mode == "subscription"`.
5. **Credentials dir:** `/home/agent/state/claude/` (agent volume, outside the repo and identity mounts); Claude Code owns `.credentials.json` inside it at 0600. Nothing in it is ever logged, in telemetry, or echoed by any endpoint.
6. `/auth/status` for anthropic: `none` / `awaiting_code` / `connected` (+ account email if cheaply obtainable from `claude` status output; expiry-warning state when the CLI reports the login nearing expiry) / `error` (last turn failed auth). `/auth/disconnect` deletes the credentials file.
7. Session roll already triggers on auth_mode change (`roll_decision` keys on it) — add a test proving `api_key → subscription` rolls.

## Workstream 3 — HelixKit UI + backend

1. Capability table: anthropic gains `subscription`, gated on a runtime probe (shim reports chaos-with-headless-clamp + claude binary present), mirroring how xAI lights up.
2. Agent settings card: for anthropic, auth-mode picker gains `Subscription account`; connect modal reuses the 260726 component with the flow direction flipped — show the sign-in link, then an *enter the code the browser shows you* field posting to `/auth/code`. Connected state shows account email and login-expiry warning when the shim reports one. The quota-honesty line is the original 260726 wording, now doing real work: *"Agent usage draws on this account's personal plan quota."*
3. Runtime error mapping: limit-hit surfaces in chat/session UI as *"Subscription limit reached — resumes ~{time}"* when the reset time is parseable, else a generic cooldown message with a settings link. Auth-expired maps to *"Subscription login expired — reconnect in agent settings."* Shapes come from the Workstream 0/2 empirical test.
4. **Consumption visibility (required by decision 1):** the shim's per-turn token telemetry already flows back with each trigger — surface the resident's rolling daily/weekly usage on the agent card, so contention with the shared account is a checked fact, not a surprise. This is the load-bearing mitigation for the shared-account decision.
5. **Wake-notices interaction:** a subscription resident that hits a cap must have wakes *suspended with a standing notice*, not retried into a failure loop — every retry is a failed turn in its session record, and on a shared account every retry also burns the operator's quota. Coordinate with the wake scheduling from 260801-01.

## Workstream 4 — Runbook note (`agent-runtime/docs/anthropic-subscription-runbook.md`)

Short now that the ceremony is in-product: which account to sign in with, what the code-paste step looks like, renewal = reconnect via the same modal when the expiry warning shows, and the two gotchas (bare mode, API-key precedence) as warnings. Plus the decision-1 context: this shares the operator's plan; if caps start binding, a dedicated account per resident is the documented upgrade (same ceremony, different sign-in).

## Non-goals

- No token custody in HelixKit (decision 2). HelixKit relays the ceremony's URL (out) and one-time code (in), transit only, never persisted or logged; long-lived credentials exist only in the agent volume.
- No dedicated per-resident accounts in this iteration (decision 1 — revisit trigger documented).
- No Claude-Code-as-harness build (fallback documented, not built).
- No Gemini change (still banned, unchanged).
- No migration; `api_key` stays the default everywhere.

## Security invariants (test, don't intend)

1. No credential, refresh token, or `.credentials.json` fragment ever appears in HelixKit DB, logs, audit trail, or shim logs/telemetry — grep-level tests on the subscription-mode flows, same as 260726. The one-time login code appears in exactly one place: the `/auth/code` request body in flight. Assert it is absent from request logs and audit payloads.
2. The exec env for a `subscription` turn has `CLAUDE_CONFIG_DIR` set and does **not** contain `ANTHROPIC_API_KEY` — assert in a shim test.
3. Clamp config for subscription turns has `bare_mode == false` — assert wherever the config is built.
4. Credentials dir is outside every mount that any HelixKit-facing endpoint can read; `.credentials.json` is 0600.

## Acceptance walkthrough

1. Connect via the modal: sign-in link opens, code pasted back, `/auth/status` goes `awaiting_code → connected`; next trigger rolls the session, runs clamped, and bills the plan (verify: zero API-key usage on the Anthropic console for that period).
2. Container kill + recreate (volume persists): still connected, no re-ceremony.
3. Disconnect: next trigger surfaces the reconnect-worded error in chat; flipping auth-mode back to `api_key` recovers on the following trigger.
4. Simulated limit-hit (empirical harness): chat shows the cooldown message with reset time; wakes suspend rather than retry-loop; the agent card's usage display reflects the burn.
5. An agent whose runtime probe reports no clamp/claude sees anthropic `subscription` greyed with the why-tooltip.

## Open questions for Mira / upstream

- Flag vs config key for headless clamp enable (Workstream 0) — whichever seuros prefers; config-key is our recommendation for resume-safety.
- Does clamp's model naming match `Chat::MODELS` ids, or does the Claude Code init model list need a mapping shim? (Clamp caches the init model list — check it against our ids early.)
- Limit-hit and auth-expired error shapes in `chaos exec --json` output when the clamped subprocess fails — needed for Workstream 3.3's mapping; establish empirically in Workstream 0's test rig.

---

*Priced context for the decision record: Max 5x is $100/mo, Max 20x $200/mo; an active resident on API billing plausibly exceeds either within weeks — which is both why the shared account is worth trying and why a dedicated one stays affordable relative to the API alternative if caps bind. The 42% figure behind decision 1 is pre-resident; Workstream 3.4 exists so the post-resident number is a checked fact. The three-flip 2026 policy history is why decision 4 is a decision and not a remark. — Lume*
