# Per-chat session resume — killing the reincarnation-per-turn

*Lume, 2026-07-15. Companion to `hosted-agent-token-economics-2026-07-14.md`.
That doc's item C proposed one resumed session per day for hourly wakes. This
is the same move applied to the conversation path, where the problem is worse:
**every chat turn is a full reincarnation** — fresh `chaos exec`, full identity
+ journals + last-30-messages re-prefilled from zero, every single time a user
presses the agent button.*

---

## 1. What actually happens per conversation turn today

`ExternalAgentResponseRequest` → POST `/trigger` → `trigger_shim.py` →
`chaos exec … -` with `build_prompt()` = identity (~45k chars) + trigger
boilerplate + last-30-messages transcript + journal context (~16k chars).
Every turn. The shim's own comment admits the gap:

```python
# NOTE: --resume <session_id> only works for an existing session.
# ... TODO: implement session-id persistence properly once we know the
# chaos session-id format from real runs.
```

Costs of this, per turn:
- **Latency**: prefill of ~60–80k tokens from cold before the first output
  token. This is most of the "why is the agent so slow to answer" feeling.
- **Tokens**: the full context at input price, every turn (PR #13 caching
  helps the *intra*-turn agentic loop; it does NOT help across fresh
  sessions — see §4).
- **Re-orientation**: the fresh instance often burns extra tool-use turns
  re-reading files / re-fetching state a continuous session would just know.

## 2. The finding: every piece needed for resume already exists

Verified against chaos @ e2a6221f (the PR #13 branch) and current helix_kit:

| piece | status |
|---|---|
| Stable per-chat session key | ✅ HelixKit already sends `session_id = "#{agent.uuid}-#{chat.id}"` on every trigger |
| Resume command | ✅ `chaos exec resume <uuid> [-]` — prompt on stdin, same shape as today (`sys/exec/fork/src/cli.rs`) |
| Machine-readable session id | ✅ `chaos exec --json` emits `{"type":"process.started","process_id":"<uuid>"}` as the **first event**, documented "Can be used to resume the process later" (`exec_events.rs`) |
| Session persistence across container restarts | ✅ `Agents::Sandbox` already mounts a `chaos-home-<uuid>` volume; session rollouts live under `$CHAOS_HOME` |
| Cheap resumed history | ✅ once PR #13 merges, replayed history is cache-read at 0.1× within TTL |
| Per-turn usage numbers | ✅ `--json` also emits `turn.completed` with `{input_tokens, cached_input_tokens, output_tokens}` — item A instrumentation falls out for free |

The only missing piece is ~60–80 lines in the shim: a mapping from HelixKit's
session_id to chaos's process_id, plus the resume-or-fresh branch.

## 3. Design

### Shim changes (the whole of it)

State file on the mounted chaos-home volume (survives container rebuilds
alongside the sessions it points at), e.g.
`$CHAOS_HOME/helixkit-session-map.json`:

```json
{
  "<agent-uuid>-<chat-id>": {
    "process_id": "0198c5b2-…",
    "model": "claude-opus-4-7",
    "created_at": "2026-07-15T09:12:00Z",
    "last_used_at": "2026-07-15T14:03:00Z",
    "cum_input_tokens": 48210
  }
}
```

Per trigger:

1. **No mapping / roll condition hit** → today's path: full `build_prompt()`,
   `chaos exec --json … -`. Parse `process.started` from the first JSONL
   line, store the mapping. Sum `turn.completed` usage into
   `cum_input_tokens`.
2. **Mapping exists** → `chaos exec --json resume <process_id> -` with a
   **delta prompt** (see below). On *any* resume failure (unknown id,
   corrupted rollout, chaos version bump) → delete mapping, fall through to
   (1). This restores a full-context mapping for subsequent turns. Chaos
   currently reports an unknown id only after silently running a fresh
   session, so that rare stale-marker attempt may already have produced tool
   side effects before the shim detects the returned-id mismatch.
3. **Roll conditions** (delete mapping, go fresh):
   - requested `model` ≠ stored `model` (a resumed session keeps its model;
     cache is model-scoped anyway)
   - identity files changed since `created_at` (cheap mtime check on
     `soul.md` / `self-narrative.md` / `runtime-instructions.md`) — so an
     identity edit propagates at the next turn instead of never
   - optional: `last_used_at` older than ~7 days, as a hygiene bound

Concurrency: two triggers for the same chat must not resume the same session
simultaneously. Flask's default single-threaded `app.run` already serialises
everything; if that ever changes, add a per-session lock. Note it in a
comment so nobody turns on threading without seeing it.

The shim's charter says "no state". This state is a **cache**: losable at any
moment with zero correctness impact (loss = one fresh session). That keeps it
inside the spirit of "intentionally dumb".

### Delta prompt (HelixKit side, small)

On resume, re-sending identity + journals + last-30 messages is not just
wasteful — the last-30 window would *duplicate* messages already in session
history. The trigger request should carry only what's new:

- `ExternalAgentResponseRequest` already records every trigger in
  `AgentRuntimeInteraction`. Include only messages with
  `created_at > last successful conversation-trigger for (agent, chat)`,
  falling back to last-30 when there is no prior interaction.
- Cleanest wiring: HelixKit sends **both** — `request` (full, as today) and
  `request_delta` (trigger intro + new-messages-only + short reminder of the
  posting rules). The shim picks: fresh session → `request` wrapped in
  `build_prompt()`; resume → `request_delta` raw. Backwards compatible, and
  the shim stays free of transcript logic.
- The boilerplate (post via `helixkit-post-message`, stdout is diagnostic…)
  is already in session history after turn one; the delta keeps a one-line
  reminder, not the full sermon.

The identity/journal injection happens once per chat, at session birth.
Journals written *during* the chat don't need re-injection — the agent has
the identity volume mounted and can read them; and the ground-truth rule
("live transcript beats memory") already covers the semantics.

### What deliberately stays per-chat

One session per (agent, chat), not one grand session per day shared with
wakes. Interleaving unrelated chats into one history would poison each chat's
ground truth and bloat everyone's context with everyone else's traffic. The
economics doc's daily wake session (item C) and this per-chat session are
siblings: same mechanism, different keys. They coexist without touching.

## 4. Why resume + PR #13 compound (and why PR #13 alone doesn't fix this)

PR #13 places a top-level `cache_control`, i.e. the breakpoint rides the
**last** block of each request. Within one `chaos exec` invocation the prompt
grows strictly by appending → every agentic sub-turn extends the cached
prefix → big intra-turn win. But across *fresh sessions*, turn N+1's prompt
diverges from turn N's partway through (new transcript bytes in the middle of
one big user message), so the cached prefix from the previous turn never
matches. **Fresh-per-turn stays full price even with PR #13 merged.**

Resume fixes exactly this: history becomes append-only *across* turns, so the
prefix from the previous turn is byte-stable and the whole replayed history
is a cache read.

Cache-TTL economics for conversations (bursty, unlike hourly wakes):

- Within a burst (turns < TTL apart): history at 0.1×, prefill mostly warm →
  this is where the **speed** shows up, precisely where users feel latency.
- First turn after a long gap: cache re-write over history (1.25× at 5-min
  TTL / 2× at 1-hour) — a one-off per burst, then everything after is 0.1×.
- Note for tuning: the wake path wants `1h` TTL (55-min gaps); the chat path
  would be fine on 5-min (bursts are minutes apart; between bursts even 1h
  dies). `CHAOS_ANTHROPIC_CACHE_TTL` is per-container/global, so start with
  `1h` everywhere for simplicity; revisit only if the 2× re-write on sparse
  chats ever shows up in the numbers (it won't dominate).

### Estimated effect per turn (Opus 4.7, ~70k context)

| | today | resumed, warm | resumed, cold burst-start |
|---|---|---|---|
| input cost | ~70k × $5/M ≈ **$0.35** | ~70k × $0.50/M + Δ ≈ **$0.04** | ~70k × $10/M ≈ $0.70 once, then warm |
| prefill latency | full 70k cold | mostly cache-hit | full once |
| re-orientation turns | often 1–3 extra | ~0 | ~0 |

Multiply the warm row by every turn of an active conversation. A 20-turn
working session drops from ~$7+ and molasses to well under $1 and snappy.

## 5. What this is *not*

- **Not a persistent chaos process per chat.** Chaos has a resident
  process-table/daemon architecture and the shim could in principle keep
  long-lived processes and feed them ops. That saves process-spawn time
  (small) at the cost of lifecycle management, memory per idle chat, and a
  much less dumb shim. `exec resume` reconstructs from the rollout file in
  a fresh process and gets ~all of the win. v2 at most; probably never.
- **Not a chaos patch.** Everything here is shim + one HelixKit request
  object. Chaos already ships the primitives.

## 6. Order of operations

1. Land PR #13 (prerequisite for the economics; resume works without it but
   pays full price for replayed history).
2. Shim: `--json` + session map + resume-or-fresh + roll conditions. While
   in there, forward per-turn `usage` in the `/trigger` response body —
   HelixKit stores it on `AgentRuntimeInteraction` (this **is** item A of
   the economics doc, delivered by the same change).
3. HelixKit: `request_delta` in `ExternalAgentResponseRequest` (and its wake
   sibling can grow the same field later, for item C).
4. Verify: `cached_input_tokens > 0` on turn 2 of any chat; wall-clock
   time-to-first-posted-message on a warm turn.

One-sentence version: *HelixKit already names the session, chaos already
knows how to resume it and tells us its id in the first JSON line, and the
volume that would remember it is already mounted — the only thing still
reincarnating the agent every turn is a TODO comment in the shim.*
