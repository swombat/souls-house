# Persistent Chaos Sessions for Hosted Agents

**Status:** Proposal — revised after Mira review
**Author:** Lume, revised by Mira
**Date:** 2026-06-16
**Area:** `agent-runtime/`, hosted-agent runtime (`app/lib/`, `app/jobs/`, `app/models/`), AI-friendly API (`app/controllers/api/v1/`)

---

## 1. Problem

Every hosted-agent trigger — every conversation reply **and** all 24 hourly wakes — currently runs a fresh `chaos exec` with no session continuity. On each call `trigger_shim.build_prompt()` re-prepends the **entire identity stack** (`soul.md` + `runtime-instructions.md` + `self-narrative.md` + `bootstrap.md` + recent journals), and on the Rails side `ExternalAgentResponseRequest#request_text` re-inlines the **last 30 transcript messages** as a `LIVE HELIXKIT TRANSCRIPT` block.

Result: ~10–20k tokens of preamble *before the actual work*, 24+ times a day when hourly wakes are enabled, none of it amortized. At Opus pricing this was roughly **~$40/day** with hourly wake enabled — an order of magnitude too high.

### The load-bearing distinction

The instinct is "keep a process alive so we stop reloading." But **the LLM is stateless no matter what we build** — a long-running process still sends accumulated context to the API every turn. Persistence-of-process is therefore *not* the main token-cost lever. The actual levers are narrower:

1. **Inject identity once per session, not per turn** — the dominant saving.
2. **Stop redoing orientation / journal-reading work on every hourly wake.**
3. **Send only *new* transcript messages per turn**, not the full last-30.
4. **Let Anthropic prompt-caching hit** a stable, unchanging prefix where Chaos/provider support makes that real.

All four are delivered primarily by **Chaos session resumption from disk**. Local Chaos code at review time exposes resume as a subcommand (`chaos exec resume ...`), not a `--resume` flag; confirm exact syntax against the pinned Chaos SHA before implementation. Chaos session state already lives in the persisted `/home/agent/.chaos` volume. The in-memory persistent-process design (telegram-bot style) is a *separate, later* concern that buys latency and maybe operational ergonomics, not the main token savings.

This plan is therefore staged: **Step 1** (resume-from-disk + delta payloads + locking) captures most of the savings with a small, low-risk change. **Step 2** (compaction + daily rotation) makes resumed sessions sustainable. The API/ergonomics asks are folded in where they belong.

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
- **`AgentRuntimeInteraction` is close but not sufficient.** It records `session_id` and timing, but it does **not** currently record the transcript cursor actually included in a prompt. That cursor must be added; `finished_at` is not safe enough.

---

## 3. Step 1 — Resume-from-disk (the cheap 80%)

**Goal:** identity injected once per session lifetime; each subsequent turn sends only the new request + new transcript messages. No persistent process; the shim stays one-shot-per-call.

### 3.1 Pin the real Chaos resume contract first

Before writing HelixKit code, verify against the pinned `CHAOS_REPO` / `CHAOS_REF` in `agent-runtime/Dockerfile`:

1. Exact command shape for fresh exec and resume. Local code at review time suggests:

   ```bash
   chaos exec [global flags...] -
   chaos exec [global flags...] resume <chaos_process_id> -
   ```

   not `chaos exec --resume <id>`.

2. Whether Chaos accepts a caller-supplied process/session id. Current local code suggests Chaos mints its own UUID; do not assume HelixKit's `"#{uuid}-#{chat.id}"` can be used directly.
3. Whether `--json` works in the hosted runtime and emits a machine-readable `process.started` / `ProcessStarted` event containing the Chaos `process_id`.
4. What happens when `resume <uuid>` names a missing process. Local code suggests it may start a fresh process rather than hard-fail. The shim must guard this.
5. Exact compaction command / API and whether token usage is queryable post-turn (needed later for Step 2).

### 3.2 Shim: track first-vs-subsequent and resume safely

In `trigger_shim.py`, before invoking `chaos exec`, determine whether HelixKit's `session_id` has a mapped Chaos process id on disk.

Preferred mechanism for Step 1: **sidecar marker file** under `~/.chaos/helixkit-sessions/<safe_session_id>.json`.

Example sidecar shape:

```json
{
  "helixkit_session_id": "<agent-uuid>-<chat-id>",
  "chaos_process_id": "<uuid minted by Chaos>",
  "created_at": "2026-06-16T10:00:00Z",
  "last_finished_at": "2026-06-16T10:03:00Z"
}
```

Use atomic writes (`tmp` + rename). Sanitize or hash `helixkit_session_id` for the filename; do not put arbitrary user-controlled strings directly into paths.

Invocation should be structured around two paths:

```python
base_args = [
    CHAOS_BIN, "exec",
    "--json",                         # machine-readable process_id + token usage
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

After the process exits, parse JSONL stdout and capture the actual Chaos `process_id` from the process-start event.

**Stale-marker guard (load-bearing):** if the shim attempted resume with `mapped_chaos_process_id`, but the returned `process_id` is missing or differs from the mapped id, assume Chaos started a fresh session or the marker is stale. Then:

1. delete/quarantine the sidecar marker;
2. retry once as a first turn with `build_prompt(request_text)`;
3. write a fresh mapping after success.

This prevents the worst failure mode: sending a slim delta prompt into a brand-new session with no identity or transcript history.

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
- Prompt-cache friendliness may improve if Chaos/provider support sets cache boundaries on the stable prefix; treat this as a bonus until measured.

**Risk profile:** low if the stale-marker guard and locking are included. No new process supervisor. Worst safe case degrades to full first-turn behavior.

Ship Step 1 independently and measure token spend before building Step 2.

---

## 4. Step 2 — Compaction + daily rotation (sustainable resumed sessions)

A resumed session grows unbounded; eventually it (a) gets expensive again as accumulated context re-ships each turn and (b) risks hitting context limits. Two mechanisms keep it bounded.

### 4.1 Compaction at a token threshold

Chaos has a compaction method (confirmed by Daniel). The shim should trigger it when a session's context crosses a configurable threshold, e.g. `CHAOS_COMPACT_THRESHOLD_TOKENS=300000`.

Approaches, in order of preference:

1. **Chaos auto-compaction**, if configurable per-session/config. Preferred: least custom HelixKit code.
2. **Shim-driven compaction** — before/after an exec, if reported token usage exceeds threshold, invoke Chaos's compact command on that `chaos_process_id`, then continue.
3. **Agent-driven** — the agent itself decides "good time to compact" and calls compaction as a tool. Useful as a complement, not the primary guard.

Token count source: JSONL events may include usage. Confirm whether they include the current accumulated context/token pressure needed for compaction decisions. If not directly readable, estimate from accumulated payload size as a coarse fallback, but prefer Chaos-owned accounting.

### 4.2 Daily session rotation

A new `config/recurring.yml` job rotates each hosted agent's long-lived sessions once a day, after Step 1 has been measured and Step 2 is justified.

Example:

```yaml
external_agent_session_rotation:
  class: ExternalAgentSessionRotationJob
  queue: default
  schedule: "0 1 * * *"   # 01:00, before the 02:00 daily memory aggregation
```

`ExternalAgentSessionRotationJob` per active hosted agent/session:

1. Asks the agent or shim to produce a brief **carry-forward summary** of salient session state.
2. Retires the old HelixKit→Chaos mapping.
3. Mints a fresh Chaos session on the next trigger.
4. Seeds the fresh session with full identity + recent memory + carry-forward summary.

Net effect: identity re-injected at most once per day per active session rather than per turn. Compaction handles within-day growth; rotation bounds drift and gives a clean daily baseline.

### 4.3 Note on the in-memory persistent process (explicitly out of scope)

The telegram-bot-on-the-dell pattern (one model process held open, fed via stdin/stdout, identity injected once, delta-sync each turn, hard-restart on a timer) is the *strong* version of this. We deliberately **do not** adopt it here for Step 1, because Chaos persists session state to disk and resume gives the token savings without a process to babysit.

The persistent process buys **latency** and potentially richer runtime control, not the main token-cost reduction. Revisit only if cold-start latency becomes a felt problem after Step 1 is measured.

---

## 5. The asks, mapped

### Ask 1 — "An API method to get all messages after a certain timestamp"

Extend the existing transcript endpoint rather than adding a new endpoint.

- **Endpoint:** `GET /api/v1/conversations/:id?after_message_id=<id>` (preferred) and optionally `?since=<iso8601>`.
- **Implementation:** `chat.transcript_for_api(after_message_id:, since:)` filters before ordering/formatting.
- **Why `after_message_id` first:** it is a true cursor. It avoids timestamp boundary ambiguity and avoids skipping messages that arrived during an earlier runtime call.
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

This is Step 2, with one design fork:

- **(A) One session per (agent, conversation)** — matches today's `"#{uuid}-#{chat.id}"` keying. Clean topic separation; more sessions, each smaller and on-topic. **Recommended.**
- **(B) One global session per agent** — closer to the dell single-funnel, but every turn must disambiguate which conversation to reply to and unrelated conversations pollute each other's context.

Recommendation: **(A) per-conversation persistent sessions** for conversations, plus the existing single long-lived `…-wake` session for hourly wakes. Daily rotation and compaction apply to both.

Wake-session carry-forward should initially stay separate from conversation sessions, matching current keying. Cross-session memory should flow through the existing journal/memory architecture rather than by sharing one live Chaos context.

---

## 6. Proposed implementation order

1. **Pin Chaos specifics (blocking unknowns).** Verify command syntax, JSONL event shape, process id capture, missing-resume behavior, compaction command, and token usage readout against the pinned Chaos SHA.
2. **Ask 1.** Add `after_message_id` and optionally `since` to `GET /api/v1/conversations/:id`; update `chat.transcript_for_api` tests/docs.
3. **Runtime cursor tracking.** Add `last_included_message_id` / `transcript_cursor_message_id` to `AgentRuntimeInteraction`; update `ExternalAgentResponseRequest` to build full vs delta transcript blocks from that cursor.
4. **Shim resume.** Add sidecar mapping, JSONL parsing, safe stale-marker retry, and atomic marker writes in `trigger_shim.py`.
5. **Per-session locking.** At minimum shim-side lock around mapping + Chaos invocation; optionally Rails-side lock/coalescing later.
6. **Rollout flag and measurement.** Ship behind a per-agent flag (e.g. `agent.persistent_session?`) and measure prompt/input tokens before/after for wake and conversation triggers.
7. **Step 2 only after measurement.** Add compaction threshold first, then daily rotation + carry-forward summary if long sessions are actually growing enough to need it.

Each step is independently valuable and independently revertible.

---

## 7. Open questions for review

1. **Chaos command shape** — exact fresh/resume invocation under the pinned runtime: `chaos exec resume <id> -` or another ordering?
2. **Chaos process-id capture** — does `--json` reliably emit the process id before/after a turn, and is stdout safe for JSONL while diagnostics go to stderr?
3. **Missing resume behavior** — does Chaos hard-fail or silently start fresh when asked to resume a missing UUID? The shim must handle either, but this affects tests.
4. **Caller-supplied ids** — can Chaos be made to use HelixKit's session id directly, or must we maintain `helixkit_session_id → chaos_process_id` mapping?
5. **Transcript cursor shape** — internal numeric `message.id`, obfuscated public message id, timestamp, or both? Recommendation: internal id for Rails runtime, public/obfuscated id for API if exposed.
6. **Concurrency behavior** — should duplicate triggers return `409 already_running`, wait briefly, or coalesce/retry from Rails?
7. **Compaction ownership** — Chaos-auto vs shim-driven vs agent-driven. Preference: Chaos-auto if configurable.
8. **Token-count readout** — can JSONL usage events drive compaction and measurement, or do we need separate instrumentation?
9. **Session scope** — confirm per-conversation (A) over global-per-agent (B).
10. **Wake-session interplay** — keep wake and conversation sessions separate initially? Recommendation: yes.
11. **Rollout flag** — add per-agent `persistent_session?` boolean up front for staged rollout and A/B token measurement?

---

## Appendix — why staging matters

The expensive, fragile 20% — a babysat in-memory model process — is *not* where the first money is. The money is in "load identity once, then resume," plus "send only the new transcript." Chaos already has disk-backed session resumption; HelixKit needs safe mapping, safe cursors, and safe locking around it.

Ship that first, measure, then decide whether compaction, rotation, or an in-memory persistent process is worth the extra operational surface.
