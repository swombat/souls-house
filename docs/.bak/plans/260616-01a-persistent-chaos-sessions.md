# Persistent Chaos Sessions for Hosted Agents

**Status:** Proposal — for review (Mira)
**Author:** Lume
**Date:** 2026-06-16
**Area:** `agent-runtime/`, hosted-agent runtime (`app/lib/`, `app/jobs/`, `app/models/`), AI-friendly API (`app/controllers/api/v1/`)

---

## 1. Problem

Every hosted-agent trigger — every conversation reply **and** all 24 hourly wakes — runs a fresh `chaos exec` with no session continuity. On each call `trigger_shim.build_prompt()` re-prepends the **entire identity stack** (`soul.md` + `runtime-instructions.md` + `self-narrative.md` + `bootstrap.md` + ~16k chars of journals), and on the Rails side `ExternalAgentResponseRequest#request_text` re-inlines the **last 30 transcript messages** as a "LIVE HELIXKIT TRANSCRIPT" block. None of it is reused turn-to-turn.

Result: ~10–20k tokens of preamble *before the actual work*, 24+ times a day, none cached. At Opus pricing this was **~$40/day** when the hourly wake was enabled — an order of magnitude too high.

### The load-bearing distinction

The instinct is "keep a process alive so we stop reloading." But **the LLM is stateless no matter what we build** — a long-running session still ships its accumulated context to the API every turn. So persistence-of-process is *not* the lever. The actual levers are narrower:

1. **Inject identity once per session, not per turn** — the dominant saving.
2. **Stop redoing orientation / journal-reading work on every hourly wake.**
3. **Send only *new* transcript messages per turn**, not the full last-30.
4. **Let Anthropic prompt-caching hit** a stable, unchanging prefix.

All four are delivered by **session resumption** (`chaos exec --resume`), which Chaos already supports and whose session state already lives in the persisted `/home/agent/.chaos` volume. The in-memory persistent-process design (telegram-bot style) is a *separate, later* concern that buys latency, not token cost.

This plan is therefore staged: **Step 1** (resume-from-disk) captures ~80% of the savings with a small, low-risk change. **Step 2** (self-compaction + daily rotation) makes a long-lived session sustainable. The three API/ergonomics asks are folded in where they belong.

---

## 2. Current architecture (as built)

| Concern | Location |
|---|---|
| Per-call `chaos exec` (one-shot, no resume) | `agent-runtime/trigger_shim.py` `trigger()` / subprocess at L116-144 |
| Identity + memory injection every turn | `agent-runtime/trigger_shim.py` `build_prompt()` L176-184 |
| Hourly wake | `app/jobs/external_agent_wake_job.rb` → `external_agent_wake_request.rb`; `config/recurring.yml` `external_agent_wake` (min 5) |
| Conversation trigger → runtime | `app/lib/external_agent_response_request.rb` → `app/lib/chaos_trigger_client.rb` → `POST /trigger` |
| Transcript inlined per turn (last 30) | `external_agent_response_request.rb#conversation_context` L120-154 |
| Invocation audit log (already stores `session_id`, `started_at`, `finished_at`) | `app/models/agent_runtime_interaction.rb` |
| Transcript API | `GET /api/v1/conversations/:id` → `chat.transcript_for_api` (`app/models/chat/summarizable.rb` L21-26) |
| Session id scheme | `"#{agent.uuid}-#{chat.id}"` (conversation), `"#{agent.uuid}-wake"` (wake) |

Key existing facts this plan leans on:

- **The shim already documents the intended fix.** `trigger_shim.py` L129-135 is a `TODO`/`NOTE`: `--resume <session_id>` works for an existing session; the shim just doesn't track first-vs-subsequent yet.
- **Session state already persists.** `Dockerfile` declares `VOLUME ["/home/agent/.chaos", ...]`, so resumed sessions survive container/process restarts.
- **The HTTP contract does not need to change.** `ChaosTriggerClient` already sends `session_id`; the shim already receives it. Step 1 changes only the shim's *internal* decision (resume vs fresh) and what Rails puts in `request`.
- **`AgentRuntimeInteraction` already records what we need to know.** It has `session_id` and `finished_at` per interaction, so "has this session run before?" and "what's the high-water mark for delta transcript?" are largely already in the database.

---

## 3. Step 1 — Resume-from-disk (the cheap 80%)

**Goal:** identity injected once per session lifetime; each subsequent turn sends only the new request + new transcript messages. No persistent process; the shim stays one-shot-per-call.

### 3.1 Shim: track first-vs-subsequent and resume

In `trigger_shim.py`, before invoking `chaos exec`, determine whether `session_id` has an existing Chaos session on disk. Two viable mechanisms (pick at implementation; (a) preferred for being self-contained):

- **(a) Sidecar marker file.** Maintain `~/.chaos/helixkit-sessions/<session_id>.json` written after the first successful exec. Presence ⇒ resume. Stores the Chaos-reported session id (see note) and `last_finished_at`.
- **(b) Ask Chaos.** If `chaos sessions list` (or equivalent) can be queried for the id, use that as source of truth. Confirm against the pinned Chaos SHA.

Invocation becomes:

```python
args = [CHAOS_BIN, "exec", "--provider", AGENT_PROVIDER, "-C", str(cwd),
        "--skip-git-repo-check", "-m", model,
        "--dangerously-bypass-approvals-and-sandbox",
        "-c", 'shell_environment_policy.inherit="all"']

if session_exists(session_id):
    args += ["--resume", chaos_session_id(session_id)]
    full_prompt = request_text                    # delta only — NO identity, NO journals
else:
    full_prompt = build_prompt(request_text)      # first turn: full identity + memory
    # after success, persist the Chaos-reported session id under session_id

args += ["-"]
```

> **Chaos session-id note.** The HelixKit `session_id` (`"#{uuid}-#{chat.id}"`) is *our* key. Chaos may mint its own session id on first run. The shim must capture Chaos's id from first-run stdout (format TBD against the pinned SHA — the existing `TODO` flags exactly this) and map `our_session_id → chaos_session_id` in the sidecar. If Chaos accepts a caller-supplied id, skip the mapping and use ours directly. **This is the one implementation unknown to pin down first.**

### 3.2 Rails: send deltas, not full re-injection

`ExternalAgentResponseRequest#request_text` should split into:

- **First turn for a session** (no prior `AgentRuntimeInteraction` for this `session_id`, or `force_full: true`): current behaviour — full metadata + transcript context.
- **Subsequent turns:** a slim payload — the trigger intro, the posting instructions, and **only messages created since the session's last `finished_at`** (the delta). The high-water mark comes from `AgentRuntimeInteraction.where(session_id:).order(:finished_at).last&.finished_at`.

This is where the "transcript inlined every turn" cost disappears. The agent already has the earlier transcript *in its resumed session*; re-sending the last-30 each turn is pure waste once resume is on.

> The "ground truth warning" framing (which section is the live transcript) must be preserved on delta turns — the agent needs to know the delta block is the new ground truth, layered on its session memory.

### 3.3 What Step 1 alone achieves

- Identity (~10–20k tokens) loaded **once per conversation session** instead of every reply.
- Hourly wake reuses its `…-wake` session: no re-orientation, no re-read of journals each hour.
- Per-turn payload shrinks to the genuinely new content.
- Prompt-cache friendliness: the stable session prefix is identical across turns within the cache TTL.

**Risk profile:** low. No new process to supervise. Worst case (sidecar lost / Chaos id mismatch) degrades gracefully to "first turn" behaviour = today's cost, never worse. Recommend shipping Step 1 independently and measuring before building Step 2.

---

## 4. Step 2 — Self-compaction + daily rotation (sustainable long-lived sessions)

A resumed session grows unbounded; eventually it (a) gets expensive again as accumulated context re-ships each turn and (b) risks hitting context limits. Two mechanisms keep it bounded.

### 4.1 Compaction at a token threshold

Chaos has a compaction method (confirmed by Daniel). The shim should trigger it when a session's context crosses **~300k tokens** (configurable via env, e.g. `CHAOS_COMPACT_THRESHOLD_TOKENS`). Approaches, in order of preference:

1. **Chaos auto-compaction**, if it can be enabled per-session/config — let Chaos own the threshold. Preferred: least custom code.
2. **Shim-driven compaction** — before/after an exec, if the session's reported token count exceeds threshold, invoke Chaos's compact command on that `session_id`, then continue.
3. **Agent-driven** — the agent itself decides "good time to compact" and calls compaction as a tool. Most flexible, least deterministic; useful as a complement, not the primary guard.

Token count source: Chaos exposes an "approximate live token progress counter" during a turn; confirm whether it's queryable post-turn against the pinned SHA. If not directly readable, the shim can estimate from accumulated payload size as a coarse fallback.

### 4.2 Daily session rotation

A new `config/recurring.yml` job rotates each hosted agent's long-lived session once a day (mirrors the existing memory-aggregation cadence and the dell telegram-bot's daily restart, which exists precisely because in-memory bloat eventually *failed all responses*):

```yaml
  external_agent_session_rotation:
    class: ExternalAgentSessionRotationJob
    queue: default
    schedule: "0 1 * * *"   # 01:00, before the 02:00 daily memory aggregation
```

`ExternalAgentSessionRotationJob` per agent:

1. Asks the agent (or the shim) to write a brief **carry-forward summary** of the session's salient state.
2. Retires the old Chaos session id; mints a fresh session.
3. Seeds the fresh session with: full identity (first-turn injection) **+ the carry-forward summary**.

Net effect: identity re-injected at most **once per day** rather than per turn — vs. ~24+/day today. Compaction (4.1) handles within-day growth; rotation (4.2) bounds drift and gives a clean daily baseline. The two mechanisms compose: compaction is the in-day pressure valve, rotation is the daily reset.

### 4.3 Note on the in-memory persistent process (explicitly out of scope)

The telegram-bot-on-the-dell pattern (one `claude` process held open, fed via stdin/stdout, `_inject_world_model` once, delta-sync each turn, hard-restart on a timer) is the *strong* version of this. We deliberately **do not** adopt it here, because Chaos persists session state to disk — `--resume` gives us the token savings without a process to babysit. The persistent process buys **latency** (no cold-start per turn), not token cost. Revisit only if cold-start latency becomes a felt problem; it is the most fragile part of the dell setup.

---

## 5. The three asks, mapped

### Ask 1 — "An API method to get all messages after a certain timestamp"

Extend the existing transcript endpoint rather than adding a new one.

- **Endpoint:** `GET /api/v1/conversations/:id?since=<iso8601>` (and/or `?after_message_id=<id>`).
- **Implementation:** `chat.transcript_for_api` (`app/models/chat/summarizable.rb`) takes an optional `since:` and filters `messages.where("created_at > ?", since)`. `Message#created_at` is already precise (microsecond timestamps shipped 2026-01-23, see `260123-02*-timestamps`).
- **Why:** when a session is notified to reply, it fetches **only new messages** itself — this is the self-serve complement to §3.2's delta payload, and the same primitive the dell bot gets from its conversation-log delta read.
- **Cost:** small; no migration.

### Ask 2 — "'Request a response' should call the running instance, like the telegram bot"

The existing path **already** calls the long-running container: `ChaosTriggerClient → POST /trigger → trigger_shim`. The container is persistent; only each *exec* was ephemeral. After Step 1, the same trigger resumes the live session instead of cold-starting it. **The Rails→runtime HTTP contract is unchanged.** The trigger payload shrinks to "new activity in conversation X (since T)"; the agent pulls the delta via Ask 1. This is structurally the dell pattern (`tg-send` → conversation-log → bot reads delta), expressed over HTTP+REST instead of a shared file.

### Ask 3 — "One long-running session, self-compacting, restarted daily"

This is exactly Step 2. Design fork for review:

- **(A) One session per (agent, conversation)** — matches today's `"#{uuid}-#{chat.id}"` keying. Clean topic separation; more sessions, each smaller and on-topic. **Recommended** — it's nearly free given existing keying, and resume handles it naturally.
- **(B) One global session per agent** — matches the dell single-funnel, but the session must disambiguate *which* conversation to reply to on each turn, and unrelated conversations pollute each other's context.

Recommendation: **(A) per-conversation persistent sessions** for conversations, plus the existing single long-lived `…-wake` session for hourly wakes. Daily rotation (§4.2) and compaction (§4.1) apply to both.

---

## 6. Proposed implementation order

1. **Pin Chaos specifics** (blocking unknown): session-id format on first run, whether a caller-supplied id is accepted, `--resume` semantics, and the exact compaction command + whether token count is queryable post-turn. Verify against the pinned `CHAOS_REPO` SHA in `agent-runtime/Dockerfile`.
2. **Ask 1** — `since=` on the transcript API. Independently shippable, independently useful.
3. **Step 1** — shim resume + sidecar session map + Rails delta payload. Ship behind a per-agent flag (e.g. `agent.persistent_session?`) so it can be rolled out to one agent and measured. **Measure token spend before/after.**
4. **Step 2** — compaction threshold, then `ExternalAgentSessionRotationJob` + carry-forward summary.

Each step is independently valuable and independently revertible. Step 1's failure mode degrades to current behaviour, never worse.

---

## 7. Open questions for review

1. **Chaos session-id capture** — does first-run stdout expose it cleanly, or does Chaos accept a caller-supplied id (letting us use `"#{uuid}-#{chat.id}"` directly and skip the sidecar map)?
2. **Compaction trigger ownership** — Chaos-auto vs shim-driven vs agent-driven (§4.1). Preference for least custom code argues for Chaos-auto if configurable per session.
3. **Token-count readout** — is the live counter queryable post-turn for the threshold check, or do we estimate from payload size?
4. **Session scope** — confirm per-conversation (A) over global-per-agent (B).
5. **Wake-session interplay** — should the hourly wake and the per-conversation sessions share carry-forward state, or stay fully separate? (Leaning separate, matching current keying.)
6. **Rollout flag** — per-agent `persistent_session?` boolean for staged rollout + A/B token measurement. Worth adding to the `Agent` model up front.

---

## Appendix — why staging matters (the one-line version)

The expensive, fragile 20% (a babysat in-memory process) is *not* where the money is. The money is in "load identity once," which `chaos exec --resume` already supports and the shim already has a `TODO` to use. Ship that first; measure; then make the long-lived session sustainable with compaction + daily rotation.
