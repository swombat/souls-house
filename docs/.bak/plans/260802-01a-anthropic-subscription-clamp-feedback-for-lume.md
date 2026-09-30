# Feedback for Lume — Plan 260802-01a, Anthropic subscription auth via Chaos clamp

**Date:** 2026-08-02  
**Reviewing:** `docs/plans/260802-01a-anthropic-subscription-clamp.md`  
**Purpose:** Plan feedback before implementation

---

## Verdict

The clamp direction is sound, but the plan needs revision before implementation. Two assumptions currently do not hold in the live HelixKit/Chaos code:

1. the proposed Claude credentials directory is not on a persistent volume; and
2. clamped turns do not emit the token telemetry that the proposed consumption display depends on.

The new auth-mode value and disconnect/wake lifecycle also need to be carried through explicitly so the implementation cannot look complete at the UI boundary while failing in persistence, accounting, or background execution.

---

## 1. HIGH — the proposed credentials directory is not persistent

The plan places Claude credentials at `/home/agent/state/claude/` and expects them to survive container recreation (`plan:50,84`).

The hosted runtime currently mounts only:

- `/home/agent/identity`
- `/home/agent/.chaos`
- `/home/agent/repo`
- `/home/agent/work`

See:

- `agent-runtime/Dockerfile:76-77`
- `app/services/agents/sandbox.rb:340-343`
- `agent-runtime/entrypoint.sh:13-17`

`/home/agent/state` therefore lives in the disposable container layer. A container image replacement or recreation would lose `.credentials.json`, so acceptance walkthrough step 2 cannot pass as written.

### Recommended correction

Add a dedicated per-agent state volume mounted at `/home/agent/state`, including:

- volume creation and deletion;
- Docker mount wiring;
- status/diagnostic reporting;
- entrypoint directory creation and ownership;
- recreation and backup expectations; and
- a boundary test showing HelixKit-facing filesystem endpoints cannot read the credentials.

Do not place Claude credentials in the identity or repository mounts. Reusing the Chaos volume would make persistence easy, but would weaken the plan's claim that the credential directory is outside every HelixKit-readable mount unless that boundary is checked explicitly.

---

## 2. HIGH — clamp does not currently provide the promised usage telemetry

Workstream 3.4 says:

> the shim's per-turn token telemetry already flows back with each trigger

That is true for the direct provider transports, but not for clamp.

The current clamped streaming path completes with `token_usage: None`:

- `chaos/sys/kern/kern/src/client/streaming.rs:843-857`

Clamp's parsed result type retains `result`, `total_cost_usd`, and `session_id`, but no usage object:

- `chaos/sys/modules/clamp/src/protocol.rs:120-128`

HelixKit's usage reporting only treats versioned invocation-local usage as trustworthy:

- `app/models/agent_runtime_interaction.rb:43-67`
- `app/models/agent_runtime_interaction.rb:149-162`
- `app/services/agent_runtime_usage_report.rb:240-261`

As a result, clamped turns will currently reach HelixKit with unknown token usage. The resident card cannot derive meaningful daily or weekly totals from the existing flow.

There is a second distinction to preserve even after telemetry is added: resident-local token counts are not the same as the shared Claude account's remaining five-hour or weekly quota. They omit Daniel's interactive Claude Code usage and every other consumer of the account.

### Recommended correction

Make clamp telemetry an explicit upstream work item:

1. Preserve Claude Code's result usage fields in `chaos-clamp`.
2. Translate them into Chaos `TokenUsage` / `TokenCount` events with an invocation-local scope.
3. Add an end-to-end `chaos exec --json` test proving clamped usage reaches the shim.
4. Label the HelixKit display accurately as resident-local activity, not account quota.
5. If Claude exposes authoritative account-limit state, probe and display it separately. Otherwise state plainly that total shared-account contention is not directly measurable yet.

Until that work exists, remove “checked fact” from Workstream 3.4 and acceptance step 4.

---

## 3. MEDIUM — `subscription` must be carried through HelixKit's complete auth-mode model

The plan introduces `auth_mode == "subscription"` and explicitly distinguishes it from `oauth_account` (`plan:46`). Workstream 2 names the shim validation change, but the value is also constrained and interpreted throughout HelixKit:

- `Agent::PROVIDER_AUTH_MODES` permits only `api_key` and `oauth_account`  
  `app/models/agent.rb:35-37`
- `AgentRuntimeInteraction` validates against that constant  
  `app/models/agent_runtime_interaction.rb:12-15`
- `record_provider_connection!` hardcodes `oauth_account`  
  `app/models/agent.rb:157-162`
- billing classification treats only `oauth_account` as subscription-based  
  `app/models/agent_runtime_interaction.rb:176-185`
- the provider-subscription controller only guards selection of `oauth_account`  
  `app/controllers/agents/provider_subscriptions_controller.rb:27-35`

Without an explicit cross-layer change list, Anthropic turns can fail interaction validation, be recorded under the wrong mode, or be presented as API-billed usage.

### Recommended correction

Add a HelixKit backend sub-workstream covering:

- `Agent::PROVIDER_AUTH_MODES`;
- provider capability constants and runtime capability parsing;
- controller selection guards;
- `record_provider_connection!` accepting the provider's actual connected mode rather than hardcoding `oauth_account`;
- every external request path that sends `auth_mode`;
- `AgentRuntimeInteraction` validation and subscription billing classification;
- cost/usage reports and filters; and
- tests for conversation, wake, Telegram, orientation, and memory-aggregation triggers.

An alternative worth considering is keeping one semantic HelixKit value such as `subscription_account` and translating it to provider-specific runtime transports (`oauth_account` or clamp) at the shim boundary. If the separate `subscription` value remains, the plan should explain why the distinction belongs in persisted product state rather than only runtime capability state.

---

## 4. MEDIUM — disconnect semantics contradict the existing lifecycle

Acceptance walkthrough step 3 says:

> Disconnect: next trigger surfaces the reconnect-worded error in chat; flipping auth-mode back to `api_key` recovers on the following trigger.

Existing disconnect behavior instead switches the provider back to API-key mode immediately:

- controller calls `clear_provider_connection!`  
  `app/controllers/agents/provider_subscriptions_controller.rb:41-45`
- `clear_provider_connection!` writes `api_key`  
  `app/models/agent.rb:165-169`

There is also a clamp-specific lifecycle edge. Clamp retains its Claude subprocess across turns:

- `chaos/sys/kern/kern/src/client/streaming.rs:631-641`

Deleting `.credentials.json` does not itself prove that a running subprocess has stopped using credentials already loaded into memory. If disconnect leaves subscription mode selected, the next trigger may continue successfully until the session or clamp transport rolls.

### Recommended correction

Choose one product contract explicitly:

#### Option A — disconnect means fallback

- Delete credentials.
- Switch immediately to `api_key`.
- Roll the persistent Chaos session so the clamp subprocess is terminated.
- Update acceptance step 3: the following trigger succeeds through API billing when an API key is available.

#### Option B — disconnect means unconnected subscription mode

- Delete credentials.
- Keep `subscription` selected.
- Force a session roll / clamp transport shutdown.
- Make the following trigger fail with the reconnect wording.

Either option needs a test proving the already-running clamped subprocess cannot survive disconnect.

---

## 5. MEDIUM — wake suspension needs a durable state and a reset contract

The plan requires cap-hit wakes to be suspended with a standing notice (`plan:60`), but the current scheduler selects every due external agent from general agent state:

- `app/jobs/external_agent_wake_job.rb:8-20`

There is no provider-cooldown state, reset timestamp, or distinction between “scheduled wakes suspended by subscription limit” and the user's ordinary `scheduled_wakes_enabled` preference.

The cited coordination target, `260801-01`, is currently `docs/plans/260801-01-telegram-inbound-media.md`, not a wake-scheduling plan.

### Recommended correction

Specify:

- the persisted field or record, e.g. `provider_cooldowns` / `subscription_limited_until`;
- whether the suspension affects only scheduled wakes or all background trigger kinds;
- how a parseable reset time clears the suspension;
- what happens when the provider gives no reset time;
- how manual conversations behave during the cooldown;
- standing-notice creation, deduplication and expiry;
- whether reconnect or switching to `api_key` clears the cooldown; and
- scheduler tests proving later wake slots do not generate repeated failed turns.

Do not overload `scheduled_wakes_enabled`; that is a user preference and should not be silently rewritten by a transient provider condition.

---

## 6. LOW — the authenticated Docker build smoke test will normally do nothing

Workstream 1 proposes:

> `claude -p 'ok'` dry check gated on token presence

Runtime account credentials are not normally available during image build, so this check will always skip in ordinary builds. Supplying live credentials to Docker build would create avoidable secret-handling and cache risks.

### Recommended correction

- Keep `claude --version` as the image-build smoke test.
- Put the authenticated check in an explicit runtime diagnostic or manual acceptance harness.
- Ensure the diagnostic reports only success/failure and reconstructed non-secret metadata.

---

## Suggested acceptance additions

Add these to the walkthrough:

1. **Image recreation, not only restart:** replace the container and prove the dedicated state volume preserves the Claude login.
2. **Disconnect with a live clamp subprocess:** connect, complete a turn, disconnect, then prove the chosen fallback/reconnect contract on the very next trigger.
3. **Telemetry provenance:** complete a clamped turn and inspect `chaos exec --json`, shim response telemetry, and `AgentRuntimeInteraction`; all three must agree on whether usage is known.
4. **No false quota claim:** the UI must distinguish resident-local activity from shared-account remaining quota.
5. **Cooldown scheduler:** simulate a limit hit, advance through another wake slot, and prove no second wake request is sent; then advance past/reset the cooldown and prove wakes resume.
6. **Auth-mode persistence:** prove `subscription` is accepted and recorded consistently for conversation, wake, Telegram, orientation, and memory aggregation paths.

---

## Ranking

| # | Severity | Finding |
|---|---|---|
| 1 | HIGH | `/home/agent/state/claude` is not on a persistent volume |
| 2 | HIGH | Clamp currently emits no token usage, so the required consumption display has no data |
| 3 | MEDIUM | The new `subscription` value is not carried through HelixKit's persisted auth-mode and billing model |
| 4 | MEDIUM | Disconnect acceptance conflicts with current fallback behavior and does not terminate a live clamp subprocess |
| 5 | MEDIUM | Wake suspension has no durable state/reset model and cites the wrong companion plan |
| 6 | LOW | Authenticated Docker-build smoke test is normally skipped and should move to runtime diagnostics |

The architecture remains viable. These findings are chiefly about carrying it all the way through persistence, telemetry, and lifecycle boundaries before calling the capability complete.
