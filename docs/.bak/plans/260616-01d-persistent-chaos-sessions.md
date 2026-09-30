# Persistent Chaos Sessions for Hosted Agents

**Status:** Proposal — revised after Mira review (`-01b`), then updated with empirical Chaos-source findings + provider-aware caching (`-01d`)
**Author:** Lume, revised by Mira, updated by Lume
**Date:** 2026-06-16
**Area:** `agent-runtime/`, hosted-agent runtime (`app/lib/`, `app/jobs/`, `app/models/`), AI-friendly API (`app/controllers/api/v1/`)

---

## What changed from `-01b` → `-01d`

A sub-agent read the Chaos source at the **pinned commit** (`CHAOS_REF=d3bb3e9418cef11c64b83326f8bb9559daf9ec2b` in `agent-runtime/Dockerfile`; confirmed `git rev-parse HEAD` matched). That resolved four of the `-01b` §7 open questions and **changed the compaction design materially**. Summary:

- **Q1 (resume syntax) — RESOLVED.** Subcommand, not a flag: `chaos exec --json resume <id> -`.
- **Q2 (id minting) — RESOLVED.** Chaos mints its own UUIDv7; the caller cannot supply an id. Surfaced as a `process.started` JSON event.
- **Q3 (missing-resume behavior) — RESOLVED, and it's the dangerous one.** A stale/unknown id **silently starts a fresh session and exits zero**. Mira's stale-marker guard is therefore load-bearing, and the only detection tell is "returned id ≠ requested id."
- **Q4 (caller-supplied ids) — RESOLVED.** Not possible → the `helixkit_session_id → chaos_process_id` sidecar map is **required**, not optional.
- **Compaction (was Q7) — CHANGED.** `/compact` is an **interactive slash command in the UI layer** (`lib/libui/slash_command.rs`), not an `exec` flag/subcommand. It may not be reachable from `chaos exec` at all. This flips **session rotation** from a secondary mechanism to the **primary** way to bound a growing session. See §4 — this is the part most in need of further thought.
- **New: provider-aware caching & wake cadence (§4.4).** The first genuinely cross-provider section, motivated by "eventually all agents will be on HelixKit."

Source citations are inline below as `path:line` against the pinned commit, so they can be re-verified.

---

## 1. Problem

Every hosted-agent trigger — every conversation reply **and** all 24 hourly wakes — currently runs a fresh `chaos exec` with no session continuity. On each call `trigger_shim.build_prompt()` re-prepends the **entire identity stack** (`soul.md` + `runtime-instructions.md` + `self-narrative.md` + `bootstrap.md` + recent journals), and on the Rails side `ExternalAgentResponseRequest#request_text` re-inlines the **last 30 transcript messages** as a `LIVE HELIXKIT TRANSCRIPT` block.

Result: ~10–20k tokens of preamble *before the actual work*, 24+ times a day when hourly wakes are enabled, none of it amortized. At Opus pricing this was roughly **~$40/day** with hourly wake enabled — an order of magnitude too high.

### The load-bearing distinction

The instinct is "keep a process alive so we stop reloading." But **the LLM is stateless no matter what we build** — a long-running process still sends accumulated context to the API every turn. Persistence-of-process is therefore *not* the main token-cost lever. The actual levers are narrower:

1. **Inject identity once per session, not per turn** — the dominant saving.
2. **Stop redoing orientation / journal-reading work on every hourly wake.**
3. **Send only *new* transcript messages per turn**, not the full last-30.
4. **Let prompt-caching hit** a stable, unchanging prefix where the provider supports it (§4.4).

All four are delivered primarily by **Chaos session resumption from disk**. Chaos session state lives in the persisted `/home/agent/.chaos` volume. The in-memory persistent-process design (telegram-bot style) is a *separate, later* concern that buys latency and maybe operational ergonomics, not the main token savings.

This plan is staged: **Step 1** (resume-from-disk + delta payloads + locking) captures most of the savings with a small, low-risk change. **Step 2** (bounding a growing session — now rotation-led, see §4) makes resumed sessions sustainable. **§4.4** layers provider-aware caching on top. The API/ergonomics asks are folded in where they belong.

---

## 2. Current architecture (as built)

| Concern | Location |
|---|---|
| Per-call `chaos exec` (one-shot, no resume) | `agent-runtime/trigger_shim.py` `trigger()` subprocess invocation |
| Identity + memory injection every turn | `agent-runtime/trigger_shim.py` `build_prompt()` |
| Hourly wake | `app/jobs/external_agent_wake_job.rb` → `external_agent_wake_request.rb`; `config/recurring.yml` `external_agent_wake` |
| Conversation trigger → runtime | `app/lib/external_agent_response_request.rb` → `app/lib/chaos_trigger_client.rb` → `POST /trigger` |
| Transcript inlined per turn (last 30) | `external_agent_response_request.rb#conversation_context` |
| Invocation audit log (already stores `session_id`, `started_at`, `finished_at`) | `app/models/agent_runtime_interaction.rb` |
| Transcript API | `GET /api/v1/conversations/:id` → `chat.transcript_for_api` (`app/models/chat/summarizable.rb`) |
| Session id scheme | `"#{agent.uuid}-#{chat.id}"` (conversation), `"#{agent.uuid}-wake"` (wake) |

Key existing facts this plan leans on:

- **The shim already documents the intended fix.** It notes that resume works for an existing session but first-vs-subsequent tracking is not implemented.
- **Session state already persists.** `agent-runtime/Dockerfile` declares `VOLUME ["/home/agent/identity", "/home/agent/.chaos", "/home/agent/repo"]`, so resumed sessions survive container/process restarts if the volume survives.
- **The HTTP contract can stay mostly stable.** `ChaosTriggerClient` already sends `session_id`; the shim already receives it. Step 1 changes the shim's internal decision (fresh vs resume) and what Rails puts in `request`.
- **`AgentRuntimeInteraction` is close but not sufficient.** It records `session_id` and timing, but it does **not** currently record the transcript cursor actually included in a prompt. That cursor must be added; `finished_at` is not safe enough (see §3.3).

---

## 3. Step 1 — Resume-from-disk (the cheap 80%)

**Goal:** identity injected once per session lifetime; each subsequent turn sends only the new request + new transcript messages. No persistent process; the shim stays one-shot-per-call.

### 3.1 The Chaos resume contract — RESOLVED against the pinned commit

These were open in `-01b §3.1`. They are now answered from source at `d3bb3e9`:

1. **Invocation shape (Q1).** Resume is a **subcommand**, not a `--resume` flag:
   ```bash
   chaos exec --json [global flags…] -                       # fresh: prompt from stdin via "-"
   chaos exec --json [global flags…] resume <SESSION_ID> -    # resume by id
   chaos exec --json [global flags…] resume --last -          # resume newest
   ```
   `--json` is a global flag on the outer `exec` Cli (`sys/exec/fork/src/cli.rs:93-100`); `resume` is a subcommand with `value_name = "SESSION_ID"` and a trailing optional `PROMPT` (`-` = stdin) (`sys/exec/fork/src/cli.rs:117-156`; in-repo test `main.rs:843`).

2. **Id minting + caller-supplied (Q2/Q4).** Chaos **mints its own** `ProcessId` (a UUIDv7) on first exec — `ProcessId::default() → Uuid::now_v7()` (`lib/libcontract/ipc/src/process_id.rs:18-23,54-58`; `chaos/session/init.rs:186`). **There is no exec-level flag to inject a caller id.** Therefore HelixKit's `"#{uuid}-#{chat.id}"` **cannot** be Chaos's id, and the sidecar map (§3.2) is **required**.

3. **Id surfacing.** Under `--json`, Chaos emits on stdout:
   ```json
   {"type":"process.started","process_id":"<uuid>"}
   ```
   (`sys/exec/fork/src/event_processor_with_jsonl_output.rs:202-208`; shape at `sys/exec/fork/src/exec_events.rs:10-14,39-43`). The shim parses this to learn the minted id. **This same event fires whether Chaos resumed or silently forked** — see Q3.

4. **Missing-resume behavior (Q3) — the dangerous one.** A well-formed-but-stale id does **not** error. `resolve_resume_process_id` returns `Ok(None)` when the id isn't in the journal (`sys/exec/fork/src/lib.rs:770-788`), and the caller turns `None` into `start_process()` — a **brand-new session** — exiting zero (`sys/exec/fork/src/lib.rs:496-514`). The existence check is a pure boolean, never an error for "not found" (`sys/kern/kern/src/rollout/recorder.rs:558-567`). **Consequence:** a resume turn against a stale id silently spins up a fresh, context-less session and feeds it only the slim delta prompt. **There is no resume-failed signal.** The only tell is that the `process.started.process_id` returned ≠ the id we asked to resume.

5. **Compaction.** Not an exec flag/subcommand — it's an interactive `/compact` slash command (`lib/libui/slash_command.rs:27,67`). See §4 — this changes Step 2.

### 3.2 Shim: track first-vs-subsequent and resume safely

In `trigger_shim.py`, before invoking `chaos exec`, look up HelixKit's `session_id` in a **sidecar map** (required, per Q4) under `~/.chaos/helixkit-sessions/<safe_session_id>.json`:

```json
{
  "helixkit_session_id": "<agent-uuid>-<chat-id>",
  "chaos_process_id": "<uuid minted by Chaos>",
  "created_at": "2026-06-16T10:00:00Z",
  "last_finished_at": "2026-06-16T10:03:00Z"
}
```

Use atomic writes (`tmp` + rename). Sanitize or hash `helixkit_session_id` for the filename; never put arbitrary user-controlled strings directly into paths. The sidecar lives on the same `/home/agent/.chaos` volume as Chaos's own session state, so the two share fate (both survive or are lost together — which keeps them consistent).

Invocation, structured around two paths:

```python
base_args = [
    CHAOS_BIN, "exec",
    "--json",                         # machine-readable process.started + token usage
    "--provider", AGENT_PROVIDER,
    "-C", str(cwd),
    "--skip-git-repo-check",
    "-m", model,
    "--dangerously-bypass-approvals-and-sandbox",
    "-c", 'shell_environment_policy.inherit="all"',
]

if mapped_chaos_process_id:
    args = base_args + ["resume", mapped_chaos_process_id, "-"]
    full_prompt = request_text         # delta only — NO identity, NO journals
else:
    args = base_args + ["-"]
    full_prompt = build_prompt(request_text)
```

After the process exits, parse the JSONL stdout and capture the actual Chaos `process_id` from the `process.started` event.

**Stale-marker guard (load-bearing — confirmed by Q3):** if the shim attempted resume with `mapped_chaos_process_id`, but the `process.started.process_id` in the output **differs from** the mapped id, Chaos silently forked a fresh session. (Per Q3 this is the *only* detectable signal — there is no error, no non-zero exit, and detection happens after that attempted run may already have produced side effects.) Then:

1. delete/quarantine the sidecar marker;
2. retry once as a first turn with `build_prompt(request_text)` (full identity + transcript);
3. write a fresh mapping after success.

This prevents subsequent turns from remaining context-less. It cannot undo tool or posting side effects from the already-completed stale-id attempt; avoiding that entirely requires Chaos to reject unknown resume ids before starting a turn.

**Failure mode:** if mapping is lost, corrupt, or stale, the fallback is full first-turn behavior. That is today's cost, not a contextless agent.

### 3.3 Rails: send deltas using transcript cursors, not `finished_at`

`ExternalAgentResponseRequest#request_text` should split into:

- **First turn for a session** (`agent.persistent_session?` disabled, no usable prior interaction cursor, or `force_full: true`): current behavior — full metadata + transcript context.
- **Subsequent turns:** a slim payload — trigger intro, posting instructions, metadata, and **only messages after the last transcript cursor that was actually included in a prompt**.

Do **not** use prior `AgentRuntimeInteraction#finished_at` as the transcript cursor. Messages can arrive while the prior agent run is still executing. Those messages have `created_at <= finished_at` but were not included in the prior prompt, so a `finished_at` cursor could skip them forever.

Add an explicit cursor to `AgentRuntimeInteraction`, preferably:

- `transcript_cursor_message_id` / `last_included_message_id` (preferred), and optionally
- `transcript_cursor_at` for diagnostics.

When building the prompt:

1. choose the message scope;
2. record the highest included message id and timestamp with the interaction;
3. next delta uses `messages.where("id > ?", last_included_message_id)` or the app's equivalent ordered primary-key cursor.

If message ids are not globally monotonic in a way we want to expose, store/use the internal id in Rails only and expose `after_message_id` through API using obfuscated/public ids as needed.

### 3.4 Delta transcript wording

On full turns, the current transcript language can remain:

```text
LIVE HELIXKIT TRANSCRIPT FROM DATABASE
...
Ground truth warning: Only the LIVE HELIXKIT TRANSCRIPT section above is the current stored conversation transcript.
```

On delta turns, use different wording:

```text
LIVE HELIXKIT TRANSCRIPT DELTA FROM DATABASE:
messages_after_cursor: <id-or-none>
message_count_included: N

BEGIN LIVE HELIXKIT TRANSCRIPT DELTA FROM DATABASE
...
END LIVE HELIXKIT TRANSCRIPT DELTA FROM DATABASE

Ground truth warning: This delta block contains newly stored database messages since the last transcript cursor included in this resumed Chaos session. Treat these new messages as ground truth for recent conversation activity. Earlier transcript context should already be present in the resumed Chaos session; if session resumption failed, the shim must retry with full context rather than sending this delta alone.
```

This avoids telling the agent that a delta block is the entire transcript.

### 3.5 Per-session locking / concurrency control

Add a lock for each HelixKit session id before invoking Chaos. Two simultaneous triggers for the same `(agent, conversation)` session must not run concurrently against the same resumed Chaos process.

Options:

- **Rails-side lock:** around `AgentRuntimeInteraction.record_trigger!` + `ChaosTriggerClient` call, keyed by `session_id`.
- **Shim-side lock:** an in-process/file lock keyed by `session_id`, close to the sidecar and Chaos invocation.
- **Both:** Rails lock for normal app behavior, shim lock as a final safety net.

Recommended minimum: shim-side lock, because the shim owns the actual session mapping and protects against multiple app instances or retries. Behavior under contention should be explicit:

- return `409 already_running`, or
- wait up to a short timeout, then run with a fresh delta cursor, or
- coalesce triggers at Rails level.

For Step 1, prefer simple and safe: reject/return `409 already_running` with enough detail for Rails to display or retry later.

### 3.6 What Step 1 alone achieves

- Identity and recent memory loaded **once per conversation session** instead of every reply.
- Hourly wake reuses its `…-wake` session: no re-orientation and journal-read on every hour.
- Per-turn payload shrinks to genuinely new content.
- Prompt-cache friendliness improves where the provider supports it — see §4.4 (treat as a measured win, not an assumed one).

**Risk profile:** low if the stale-marker guard and locking are included. No new process supervisor. The main residual risk is the narrow stale-id window above: Chaos can run one delta-only turn before returning the mismatched id.

Ship Step 1 independently and measure token spend before building Step 2.

---

## 4. Step 2 — Bounding a growing session (rotation-led; compaction uncertain)

A resumed session grows unbounded; eventually it (a) gets expensive again as accumulated context re-ships each turn and (b) risks hitting context limits. `-01b` proposed compaction-at-a-threshold as the primary in-day bound, with daily rotation as backstop. **The source finding inverts that priority.**

### 4.1 Compaction — the open problem (this is the part for Mira)

**What the source says:** `/compact` is an **interactive slash command** defined in the UI layer (`lib/libui/slash_command.rs:27,67`), described as "summarize conversation to prevent hitting the context limit." It is **not** an `exec` flag or subcommand. The sub-agent found no exec-level compaction entry point.

**Why this matters:** the entire hosted design drives `chaos exec` — the non-interactive, one-shot, piped path. It never runs the interactive TUI. So the three `-01b` options must be re-evaluated against "can this even be invoked from `exec`?":

1. **Shim-driven compaction (invoke a compact command)** — ❌ **dead as written.** There is no exec compaction command to invoke. `-01b`'s preferred-ish option #2 is off the table.
2. **Agent-driven (agent calls `/compact` itself)** — ⚠️ **uncertain.** Slash commands appear to be a UI-layer construct. Whether an agent running inside `chaos exec` can issue `/compact` (and have it take effect on the persisted session) is **unverified** and is the key open question. If exec has no slash-command channel, this is also dead.
3. **Chaos auto-compaction at a threshold** — ⚠️ **unverified.** The `/compact` help text ("prevent hitting the context limit") *hints* Chaos is context-limit-aware, but the sub-agent found only the manual command, not an automatic trigger in the exec path. Needs a targeted source check or a runtime probe (drive a session past the limit and observe).
4. **External rotation-with-summary** — ✅ **fully under HelixKit's control** (see §4.2). This is the only mechanism we can guarantee works through `exec`.

**Consequence — rotation is now primary, not backup.** If neither (2) nor (3) turns out to be invocable from `exec`, **rotation-with-summary (§4.2) is the only available lever** to bound a session, and it must be token-triggered (not just daily). Step 2 should therefore *lead* with rotation and treat compaction as an optimization to adopt only if (2) or (3) is verified.

**Concrete questions for Mira / the next investigation pass:**
- Can a `chaos exec` agent invoke `/compact` (or any compaction) from inside its run? If so, how — a tool, a special stdin token, a config?
- Does `chaos exec` **auto-compact** when the context approaches the limit, or does it error/truncate? (The §4.2 rotation trigger depends on whether we must pre-empt this ourselves.)
- Is per-session token usage queryable from the `--json` event stream (needed to *trigger* rotation/compaction at a threshold at all)? `-01b`'s Q8 — still open, and now more central because rotation needs a trigger signal.

### 4.2 Rotation-with-summary (primary bounding mechanism)

Rotate a session when either condition fires:

- **Token threshold** (in-day bound, replacing shim-driven compaction): when the session's context crosses a configurable threshold, e.g. `CHAOS_ROTATE_THRESHOLD_TOKENS=300000`. *Requires* a token-usage signal (see §4.1 third bullet); if none is available from `--json`, fall back to a coarse estimate from accumulated payload bytes, and `log()` that the bound is approximate.
- **Daily** (drift bound + clean baseline): a `config/recurring.yml` job, after Step 1 has been measured.

```yaml
external_agent_session_rotation:
  class: ExternalAgentSessionRotationJob
  queue: default
  schedule: "0 1 * * *"   # 01:00, before the 02:00 daily memory aggregation
```

`ExternalAgentSessionRotationJob` per active hosted agent/session:

1. Asks the agent (or shim) to produce a brief **carry-forward summary** of salient session state.
2. Retires the old HelixKit→Chaos mapping (delete/quarantine the sidecar).
3. On the next trigger, the shim sees no mapping → **mints a fresh Chaos session** (first-turn path).
4. That fresh first turn is seeded with full identity + recent memory + the carry-forward summary.

Net effect: identity re-injected at most once per rotation (≥ once/day) rather than per turn. A token-triggered rotation also caps the worst-case per-turn re-ship cost. Because rotation reuses the existing first-turn path and sidecar mechanics, it needs **no Chaos compaction support at all** — which is exactly why it's the safe primary.

### 4.3 Note on the in-memory persistent process (explicitly out of scope)

The telegram-bot-on-the-dell pattern (one model process held open, fed via stdin/stdout, identity injected once, delta-sync each turn, hard-restart on a timer) is the *strong* version of this. We deliberately **do not** adopt it here for Step 1, because Chaos persists session state to disk and resume gives the token savings without a process to babysit. The persistent process buys **latency** and potentially richer runtime control (and would give a slash-command channel, making compaction reachable) — not the main token-cost reduction. Revisit only if cold-start latency becomes a felt problem, or if compaction-from-exec proves impossible and the latency/control trade is worth it.

### 4.4 Provider-aware caching & wake cadence (NEW — first cross-provider section)

Motivated by "eventually all agents will be on HelixKit," not just Chaos-on-Anthropic. Two distinct wins with **different reach**:

**(a) Reuse the resumed session within a window — universal.** "Identity once, no re-orientation, resume from disk" works on every provider. This is just Step 1; generalize it as the default.

**(b) Stay inside a long cache window to make re-shipping cheap — Anthropic/Gemini only.** Prompt-cache lifetimes differ by provider:

| Provider | Holdable cache window |
|---|---|
| Claude (Anthropic) | 5 min default; **1 h** via `cache_control: {ttl: "1h"}` |
| Gemini | implicit ≤24h (uncontrolled); explicit caching with **arbitrary TTL** (storage cost) |
| OpenAI (GPT) | automatic 5–10 min, **uncontrollable** (Azure variant: up to 24h) |
| xAI (Grok) | automatic, undocumented, ~short |

So the cadence optimization only applies where the provider lets us pin a long TTL (Anthropic, Gemini-explicit). On OpenAI/Grok a wake session still gets the **resume** win but won't get cache warmth at any sane cadence.

**The cadence inversion (waking *more* often can be cheaper).** If the cache TTL is **sliding** (refreshes on each hit), then:
- waking every **45 min** under a **1 h** TTL keeps the cache warm and pushes its expiry out each time → the stable prefix re-ships at ~0.1× (cache read), and the 2× write premium is paid only once per session (at rotation);
- waking exactly **hourly** under a 1 h TTL sits on the expiry boundary → misses about as often as it hits → pays the 2× write *and* the full re-ship.

Rough Opus numbers for a ~30k-prefix wake session with light per-wake work: hourly-cold ≈ **$4.4/day**, 45m-warm ≈ **$2.2/day** — about half the cost *despite 33% more wakes*.

**The condition that decides it (must be measured, not assumed).** The cache only ever discounts the re-shipped *prefix*. **Output tokens are never cacheable and scale linearly with wake frequency.** So the inversion holds **only while wakes are mostly cheap no-ops** (look, decide nothing, exit) and **reverses** under heavy per-wake output. This happens to align with how the wake is already told to behave (`ExternalAgentResponseRequest` already instructs "do not post merely to acknowledge wakefulness"), so the cost-optimal cadence and the behaviorally-correct cadence point the same way — but the design must be **gated on measured output-tokens-per-wake**, and tightened only while that stays low.

**Interaction with rotation (§4.2).** "Keep warm forever" fights "session grows unbounded." They reconcile: the **daily rotation is the one scheduled cache-cold moment** (fresh identity, fresh 2× write), and sub-TTL wakes keep it warm in between — one cold write per day per session, warm the rest. No new mechanism needed.

**Provider-aware design:**
1. Resume-and-reuse-within-window: universal default (Step 1).
2. `cache_ttl` + cadence optimization gated on provider capability — set `ttl: "1h"` on the stable prefix for Anthropic/Gemini; tune wake cadence *below* the TTL (e.g. 45m for a 1h window) **only while measured output-per-wake stays low**.
3. Open questions for §7 (caching): is the target provider's cache TTL **sliding-on-use or fixed-from-creation**? (The whole inversion depends on sliding.) Does Chaos expose **per-request cache-TTL config** so the shim can set `1h` on the prefix?

---

## 5. The asks, mapped

### Ask 1 — "An API method to get all messages after a certain timestamp"

Extend the existing transcript endpoint rather than adding a new endpoint.

- **Endpoint:** `GET /api/v1/conversations/:id?after_message_id=<id>` (preferred) and optionally `?since=<iso8601>`.
- **Implementation:** `chat.transcript_for_api(after_message_id:, since:)` filters before ordering/formatting.
- **Why `after_message_id` first:** it is a true cursor. It avoids timestamp boundary ambiguity and avoids skipping messages that arrived during an earlier runtime call (same reason as §3.3).
- **Why keep `since`:** useful for human/debug clients and API ergonomics, but not the primary runtime cursor.
- **Cost:** small; no migration for API alone. Runtime cursor tracking does need a migration on `agent_runtime_interactions`.

### Ask 2 — "'Request a response' should call the running instance, like the telegram bot"

The existing path already calls the long-running container:

```text
ChaosTriggerClient → POST /trigger → trigger_shim
```

The container is persistent; only each `chaos exec` is ephemeral. After Step 1, the same trigger resumes the persisted Chaos session instead of cold-starting it. **The Rails→runtime HTTP contract stays mostly unchanged.** The trigger payload shrinks to "new activity in conversation X after cursor Y"; the agent can also self-serve fresh deltas through Ask 1.

This is structurally similar to the dell pattern (`tg-send` → conversation-log delta read → model reply), without committing yet to a babysat in-memory model process.

### Ask 3 — "One long-running session, self-compacting, restarted daily"

This is Step 2 (§4), with the compaction caveat (§4.1) and one design fork:

- **(A) One session per (agent, conversation)** — matches today's `"#{uuid}-#{chat.id}"` keying. Clean topic separation; more sessions, each smaller and on-topic. **Recommended.**
- **(B) One global session per agent** — closer to the dell single-funnel, but every turn must disambiguate which conversation to reply to and unrelated conversations pollute each other's context.

Recommendation: **(A) per-conversation persistent sessions** for conversations, plus the existing single long-lived `…-wake` session for hourly wakes. Rotation (and compaction, if available) apply to both.

Wake-session carry-forward should initially stay separate from conversation sessions, matching current keying. Cross-session memory should flow through the existing journal/memory architecture rather than by sharing one live Chaos context.

---

## 6. Proposed implementation order

1. **Pin remaining Chaos specifics.** Q1–Q4 are resolved (§3.1). Still to verify: **can `exec` agents invoke compaction / does `exec` auto-compact** (§4.1), **is token usage queryable from `--json`** (§4.1/§4.4), and **cache TTL sliding-vs-fixed + Chaos cache-TTL config** (§4.4). A short source pass + one runtime probe should settle these.
2. **Ask 1.** Add `after_message_id` and optionally `since` to `GET /api/v1/conversations/:id`; update `chat.transcript_for_api` tests/docs.
3. **Runtime cursor tracking.** Add `last_included_message_id` / `transcript_cursor_message_id` to `AgentRuntimeInteraction`; update `ExternalAgentResponseRequest` to build full vs delta transcript blocks from that cursor.
4. **Shim resume.** Sidecar mapping (required), `--json` JSONL parsing, `process.started` id capture, **id-mismatch stale-marker guard** (§3.2), atomic marker writes in `trigger_shim.py`.
5. **Per-session locking.** At minimum shim-side lock around mapping + Chaos invocation; optionally Rails-side lock/coalescing later.
6. **Rollout flag and measurement.** Ship behind a per-agent flag (e.g. `agent.persistent_session?`) and measure prompt/input/**output** tokens before/after for wake and conversation triggers. (Output-per-wake is the gate for §4.4.)
7. **Step 2 only after measurement.** Lead with **rotation-with-summary** (§4.2). Adopt compaction only if §4.1's open questions resolve in favor of an exec-reachable path.
8. **Provider-aware caching (§4.4)** once TTL behavior is verified — set `ttl: "1h"` for Anthropic/Gemini and tune wake cadence while output-per-wake stays low.

Each step is independently valuable and independently revertible.

---

## 7. Open questions for review

**Resolved since `-01b`** (kept for the record, with source):
- ~~Q1 Chaos command shape~~ → `chaos exec --json resume <id> -` (`cli.rs:117-156`).
- ~~Q2 process-id capture~~ → `{"type":"process.started","process_id":"<uuid>"}` under `--json` (`event_processor_with_jsonl_output.rs:202-208`, `exec_events.rs:39-43`).
- ~~Q3 missing-resume behavior~~ → **silent fresh session, exit zero** (`lib.rs:770-788`, `:496-514`); detect via returned-id ≠ requested-id.
- ~~Q4 caller-supplied ids~~ → **not possible** (UUIDv7 minted, `process_id.rs:54-58`); sidecar map required.

**Still open:**
1. **Compaction reachability (was Q7 — now the headline).** Can a `chaos exec` agent invoke `/compact`, or does `exec` auto-compact at the context limit? If neither, rotation (§4.2) is the *only* bound — confirm we're comfortable with that. (Source pass + runtime probe.)
2. **Token-usage readout (Q8).** Is per-session/accumulated token usage in the `--json` event stream? Needed to *trigger* both rotation thresholds and the §4.4 cadence gate. If absent, we estimate from payload bytes.
3. **Cache TTL semantics (§4.4).** Sliding-on-use or fixed-from-creation? The cadence inversion depends on sliding.
4. **Chaos cache-TTL config (§4.4).** Does Chaos let the shim set `cache_control: {ttl: "1h"}` on the stable prefix, per provider?
5. **Transcript cursor shape (Q5).** Internal numeric `message.id`, obfuscated public id, timestamp, or both? Recommendation: internal id for Rails runtime, public/obfuscated id for API if exposed.
6. **Concurrency behavior (Q6).** Duplicate triggers → `409 already_running`, wait briefly, or coalesce/retry from Rails?
7. **Session scope (Q9).** Confirm per-conversation (A) over global-per-agent (B).
8. **Wake-session interplay (Q10).** Keep wake and conversation sessions separate initially? Recommendation: yes.
9. **Rollout flag (Q11).** Add per-agent `persistent_session?` boolean up front for staged rollout and A/B token measurement?
10. **Output-per-wake gate (§4.4).** What threshold of measured output-tokens-per-wake flips the cadence optimization off? Decide after Step 1 measurement.

---

## Appendix — why staging matters

The expensive, fragile 20% — a babysat in-memory model process — is *not* where the first money is. The money is in "load identity once, then resume," plus "send only the new transcript." Chaos has disk-backed session resumption; HelixKit needs safe mapping, safe cursors, safe locking around it.

The source investigation also re-confirmed a pattern worth keeping in view: every place this plan assumed a Chaos capability *by its convenient shape*, the pinned source contradicted it (`finished_at` cursor, `--resume` flag, shim-driven compaction). Resolve the remaining compaction/token-usage/cache-TTL unknowns against the **pinned source + a runtime probe** before building Step 2 — don't design on the assumed shape.

Ship Step 1 first, measure, then decide whether rotation alone suffices or compaction is worth chasing through `exec`.
