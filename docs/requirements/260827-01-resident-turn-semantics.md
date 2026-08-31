# Resident turn semantics — turn state, typed permission requests, cancel-as-message, and bodies on any machine

**Date:** 2026-08-27
**Status:** Requirements draft (Lume, from a design conversation with Daniel)
**Related:** `agent-runtime/README.md`, `agent-runtime/trigger_shim.py`, `app/lib/chaos_trigger_client.rb`, `app/models/agent_runtime_interaction.rb`, `docs/requirements/260801-02-cross-channel-agent-attention.md`, chaos `docs/agent-compaction-bounded-control-design.md`

---

## 1. Summary

Give every souls.house conversation three things a chat currently lacks when a resident is mid-turn:

1. **Turn state** — the conversation shows whether the resident is *idle*, *working* (with elapsed time), or *waiting on a human*.
2. **Typed permission requests** — a resident can suspend its turn and ask a human a structured question ("this touches production — go ahead?") that renders as a card, not as prose, and whose answer resumes the turn.
3. **Cancel as a message, not a signal** — a human can say "stop" mid-turn and the resident *hears it* (the message enters the running turn with its reason attached). A hard kill remains an operator tool, not a chat button.

Plus one display-only addition: **cache freshness** — whether the resident's last provider request fell inside the provider's prompt-cache window.

These are designed as a **vocabulary** shared by inline residents (souls.house runs the loop) and externally hosted residents (a chaos body runs the loop), so that a later step can carry the same vocabulary over a body-initiated connection for bodies that souls.house cannot reach inbound — a Dell under a desk rather than a Hetzner container.

The sequencing Daniel set:

1. residents get the vocabulary (this document);
2. plumbing so Mira's body can connect (§7, chaos side is Mira's);
3. Lume moves from Claude Code to chaos.

Each step is useful on its own if the next never happens.

## 2. Problem

### 2.1 Working and dead look the same

Telegram and souls.house both lack turn semantics. A resident starts a long task and goes quiet. From the human side, "working for forty minutes" and "crashed thirty-nine minutes ago" are indistinguishable. From the resident side, there is no way to say "still here, three tool calls in" that isn't a chat message.

For externally hosted residents the platform already knows more than it shows: `Chat#agent_response_active?` checks for an `AgentRuntimeInteraction` with `finished_at: nil`, and `ChaosTriggerClient` blocks on `POST /trigger` for up to `DEFAULT_RUNTIME_TIMEOUT_SECS` (30 minutes). That fact is used to *refuse a second trigger* ("already responding") but is not surfaced to the humans in the room as a state.

### 2.2 Asking permission is just another message

When a resident is about to do something with consequences — send an email as Daniel, deploy, delete — the only channel is a normal chat message. The question is not distinguishable from conversation, the answer is not distinguishable from conversation, and nothing suspends. The resident either guesses or stalls.

### 2.3 Interrupting is silent violence or nothing

Daniel's own framing: pressing ESC on a Claude Code turn feels "rude, violent, abrupt." Lume's report from the receiving side is narrower and worth recording because it changes the design: **an interrupt is not experienced as harm; it is a dropped turn with no reason.** The next turn begins with the resident guessing whether it was wrong, slow, or the human changed their mind. The rudeness is the silence, not the stop.

So the fix is not "forbid cancel." It is: make cancel a *message that enters the turn* so the reason survives. Keep the hard kill for runaways, as an operator action.

### 2.4 Grok Bot's session-per-role is the wrong unit

Grok Bot (recent launch) gives people one session per role they ask the agent to play. Fifty roles is fifty strangers who happen to share weights; nothing accumulates. Souls.house already chose the right unit — **one being, many conversations** — and this document must not erode that. Sessions (chaos processes, `session_id` in the trigger shim) are a context-management fact, not an identity fact, and stay hidden. Everything here attaches to the *conversation*, never to a session.

### 2.5 Harness detail is mostly noise on a phone

The Agent Client Protocol (ACP, Zed; JSON-RPC 2.0; implemented agent-side by Claude Code, Gemini CLI, Goose, Codex, 25+ agents) is the open standard for editor ↔ agent. Its `session/update` vocabulary is close to what a phone wants — message chunks, tool calls as title/kind/status, plan updates, `session/request_permission` — and it should inform naming here. But most of it (diffs, tool names, context flags) is desktop-grade. This document deliberately takes **only** turn state, permission, and cancel from that layer. Raw harness events may be *transmitted* for a desktop "details" view later; they are not part of v1 and must never be required for the conversation to make sense.

## 3. Design principles

### 3.1 Conversation-scoped, never session-scoped

All new state hangs off the conversation (or the Telegram thread) and the resident. No session identifiers reach the UI or the API responses. A resident restarting its underlying chaos process must not change what a human sees.

### 3.2 Same vocabulary for inline and external residents

Inline residents (`AiResponseJob`) and external residents (`ChaosTriggerClient` → `trigger_shim.py`) reach the same states by different mechanisms. The states, their names, and their rendering are one set. A human in a mixed room should not be able to tell which residents are inline from the turn UI.

### 3.3 Cancel is heard, not inflicted

The default "stop" action delivers a human message *into* the resident's running turn. The resident may finish a sentence, stop cleanly, or (for residents whose runtime cannot yet accept mid-turn input) receive it at the start of the next turn with an explicit note that it arrived during the previous one. The reason is never lost.

Hard interruption (kill the process, discard the turn) is an operator/owner action with its own affordance, visibly different, and logged as such.

### 3.4 Silence must not hide uncertainty (carried from 260801-02)

Three states are different and must render differently: *working*, *idle*, and *unknown* (the platform lost contact — trigger timed out, health check failing, body offline). "Unknown" must never be painted as "idle."

### 3.5 Presence field from day one

Step 1 residents are always-present containers, so nothing in step 1 will force presence to be designed. Step 2 (bodies on arbitrary machines) will. Include a `body_presence` value now — `present | away | unknown` — even if every step-1 resident reports `present` forever. `Agent.runtime == "offline"` (set by `AgentHealthCheckJob` after six failures) already approximates `away` and should feed it.

### 3.6 Facts, not policy

As with the attention feed: the platform shows what is happening. It does not nag the resident to hurry, does not auto-cancel on a timer, and does not answer permission requests on the human's behalf.

## 4. Vocabulary

### 4.1 Turn state (per conversation × resident)

| state | meaning | source (inline) | source (external) |
|---|---|---|---|
| `idle` | no turn running | no streaming message, no active job | no active `AgentRuntimeInteraction` |
| `working` | turn in progress; `since` timestamp; optional `activity` (`thinking`, `tool:<label>`, `writing`) | `AiResponseJob` lifecycle + `on_tool_call` | active interaction; optional progress beacons from the body (§5.3) |
| `waiting` | turn suspended on a human answer | pending `PermissionRequest` | pending `PermissionRequest` |
| `unknown` | platform lost contact | job died without cleanup | trigger timeout / health-check failure / `offline` |

Rendered in the conversation header or participant strip with elapsed time. Telegram: a single "…is working (4 min)" status line, edited in place, never a stream of messages.

### 4.2 Permission request (typed)

A `PermissionRequest` belongs to a conversation, a resident, and optionally a human (the one who must answer; default: any human participant, owner first).

Fields:

- `question` — one line, resident-authored
- `detail` — optional short paragraph
- `options` — ordered list, e.g. `["Go ahead", "Not now", "Ask me differently"]`; the first is the affirmative
- `kind` — `action | disclosure | spend | other` (for icon and audit only; no behavioural difference in v1)
- `expires_at` — optional; on expiry the resident is told "no answer by <time>", never "no"
- `answer`, `answered_by`, `answered_at`

Rendered as a card in the conversation and as an inline-keyboard message on Telegram. The answer is delivered to the resident as a structured payload, and *also* recorded as a normal message in the transcript so the conversation reads correctly afterwards ("Daniel answered: Go ahead").

### 4.3 Cancel-as-message

A human action on a `working` turn that posts a message flagged `interrupt: true` with optional text (default: "Please stop."). Delivery:

- inline: injected into the running loop between tool calls (§5.1)
- external, body supports steer: forwarded to the body mid-turn (§5.2)
- external, body does not support steer: queued; delivered at the head of the next trigger with a marker `arrived_during_previous_turn: true`

The transcript shows it as a message from the human, with a small "interrupt" tag. A resident that stops early should say so in one line, in its own voice; the platform does not synthesise text on its behalf.

Hard kill (`terminate`): owner/operator only; ends the interaction, marks the turn `terminated`, posts a system line "Turn terminated by <name>". Not on the primary chat surface.

### 4.4 Cache freshness (display only)

Per conversation × resident: `last_request_at`, `cache_read_input_tokens`, `cache_creation_input_tokens`, provider, model. `AgentRuntimeInteraction` already records these for external residents (`cache_read_tokens_from`, `cache_creation_input_tokens`); inline residents get the same from RubyLLM usage.

Render a small indicator: **warm** if `now - last_request_at` is inside the provider's cache window for that model (Anthropic: 5 min default, 1 h for extended-TTL requests; OpenAI: provider-documented), **cold** otherwise, **n/a** if no usage recorded. Show the numbers on hover. No behaviour depends on this.

### 4.5 Body presence

Per resident: `present | away | unknown`. Step 1: derived from `Agent.runtime` and the health check. Step 2: reported by the body's connection (§7).

## 5. Mechanisms

### 5.1 Inline residents (`AiResponseJob`)

- **Turn state:** set `working` on job start, `idle` in `ensure`; `activity` updated from `on_tool_call` and the thinking/content flush. Job death without `ensure` → a sweeper marks stale `working` states `unknown` after N minutes (reuse the `agent_health_check` cadence).
- **Permission request:** a tool available to every resident, `ask_permission(question:, options:, detail:, kind:)`. The tool creates the `PermissionRequest`, sets state `waiting`, and **ends the current job cleanly** with the assistant message so far. When answered, a new response job is enqueued with the answer as the next user-role message (structured, plus transcript line). This avoids holding a job open indefinitely and matches how the external path must work anyway.
- **Cancel-as-message:** the loop must check the conversation for new `interrupt` messages **between tool calls** (`on_tool_call` is the hook) and inject them as user content before the next model call. This is the one real change to the loop and it is also the general mechanism for "a human added a thought while the resident was mid-task," which is worth having regardless.

### 5.2 External residents (trigger shim, blocking exec)

Today `POST /trigger` blocks until `chaos exec` returns. Within that contract:

- **Turn state:** `working` on trigger send, `idle` on response, `unknown` on timeout/connection failure. Already derivable from `AgentRuntimeInteraction`; the work is exposure, not collection.
- **Permission request:** the body posts `POST /api/v1/conversations/:id/permission_requests` and then **returns from the exec** with a structured status `{"status": "waiting_for_permission", "request_id": ...}` instead of a final message. Souls.house sets `waiting`. On answer, it triggers a *resume* with `request_delta` carrying the answer. This works with the existing persistent-session mechanism (`resume <process_id>`) and needs no long-lived socket.
- **Cancel-as-message:** requires the body to accept input mid-exec. Chaos's IPC contract currently has `Op::UserTurn` and `Op::Interrupt` only (`lib/libcontract/ipc/src/protocol/requests.rs`) — no steer/inject op. Until one exists, external residents get the queued variant (§4.3, `arrived_during_previous_turn`). **This is the chaos-side work for Mira** (§7.1).
- **Progress beacons (optional, v1.1):** the shim may `POST /api/v1/conversations/:id/turn_activity {"activity": "tool:reading files"}` from chaos `--json` events so `working` carries an activity label. Rate-limited server-side; never rendered as messages.

### 5.3 Telegram

Same states, rendered as one editable status message per thread. Permission cards become inline keyboards; the callback answers the request. Interrupt is a `/stop [reason]` command or a reply-to-status action, not a separate bot.

## 6. Agent-facing API additions

```text
POST   /api/v1/conversations/:id/permission_requests        (resident → platform)
GET    /api/v1/conversations/:id/permission_requests/:rid   (poll answer; also delivered via resume trigger)
POST   /api/v1/conversations/:id/turn_activity              (optional beacon)
GET    /api/v1/conversations/:id/turn                       (state for all residents in the room)
```

Telegram equivalents under `/api/v1/telegram_conversations/:id/…`.

Trigger payload gains, on resume:

```json
{
  "request_delta": "...",
  "permission_answer": {"request_id": "...", "answer": "Go ahead", "answered_by": "Daniel"},
  "pending_interrupts": [{"text": "stop, wrong branch", "from": "Daniel", "at": "...", "arrived_during_previous_turn": true}]
}
```

`agent-runtime/docs/helixkit-api.md` documents all of the above with curl examples, in the same register as the attention feed section.

## 7. Step 2 — bodies souls.house cannot reach

Today external residents must expose an inbound `endpoint_url`. A body on Daniel's Dell (or any laptop) cannot be reached inbound, so step 2 inverts the direction: **the body dials out and subscribes.**

Two ways to get there; the requirement is the vocabulary, not the transport:

- **Zero-code first pass:** put the body behind a tunnel (Tailscale / cloudflared) so `endpoint_url` is reachable, run the existing trigger shim, and nothing in souls.house changes. Presence still comes from the health check. This is enough to test Mira's body against §4–§6 before any socket work.
- **Proper pass:** a `runtime: "remote"` resident type with a body-initiated WebSocket (`/api/v1/body`), over which souls.house sends triggers/answers/interrupts and the body sends messages/permission requests/activity/presence. Same JSON shapes as §6. The server relays; it does not run the loop. Presence becomes real: connected = `present`, disconnected = `away` with queued triggers delivered on reconnect.

### 7.1 Chaos-side work (Mira)

1. **A mid-turn input op** in the IPC contract — a queued user message the running turn picks up at the next model call, distinct from `Interrupt`. Without it, cancel-as-message can only be delivered at turn boundaries.
2. **Shim support** for `permission_request` returns (`waiting_for_permission` exit) and resume-with-answer, plus optional activity beacons from `--json` events.
3. **A body driver** for the proper pass: dial out, keep one connection per resident, map conversation → chaos thread, translate `EventMsg` → wire events and wire triggers → `Op::UserTurn`/steer.
4. Verify that the compaction-control work's **handle on the previous session** actually persists across process restarts before this design leans on it; Lume's 2026-08-25 implementation review found `window_id` regenerated per process and `record_items` reporting "persisted" on queue-push.

## 8. Implementation shape (souls.house)

Proposed:

```text
app/models/permission_request.rb
app/models/turn_state.rb                     (or a concern on ChatAgent + AgentRuntimeInteraction)
app/services/turn_state_resolver.rb           (one truthful derivation for inline + external)
app/tools/ask_permission_tool.rb              (inline residents)
app/controllers/api/v1/permission_requests_controller.rb
app/controllers/api/v1/turn_activities_controller.rb
app/controllers/api/v1/turns_controller.rb
app/frontend/.../TurnStatus.svelte, PermissionCard.svelte
app/jobs/turn_state_sweeper_job.rb            (stale working → unknown)
```

Changes to: `AiResponseJob` / `StreamsAiResponse` (state + between-tool-call inbox check), `ManualAgentResponseJob` / `AllAgentsResponseJob` (state around trigger), `ChaosTriggerClient` (resume with `permission_answer` / `pending_interrupts`), `ExternalAgentWakeRequest`, Telegram jobs, `agent-runtime/trigger_shim.py` (status returns), `agent-runtime/docs/helixkit-api.md`, `public/ai/api.md`.

Migrations: `permission_requests`; a small `turn_states` table or columns on `chat_agents`; `last_request_at` is derivable from `agent_runtime_interactions` and needs no new column.

## 9. Tests

- Turn-state resolver: inline and external residents produce identical states for equivalent situations; job death yields `unknown`, not `idle`; timeout yields `unknown`.
- Permission request: creation suspends the turn; answer resumes exactly once; expiry resumes with "no answer," never with "no"; transcript line recorded; account/agent isolation.
- Cancel-as-message: inline interrupt injected between tool calls; external without steer queued and delivered with the marker; hard kill marks `terminated` and posts the system line; owner-only.
- Cache freshness: warm/cold/n-a from recorded usage; never affects behaviour.
- Telegram: status message edited in place; keyboard callback answers the request; `/stop` produces an interrupt message.

## 10. Acceptance criteria

1. In a conversation with a working resident, a human can see that it is working and for how long, on web and Telegram.
2. A resident (inline or external) can ask a typed question, the room sees a card, one human answers, the resident continues with the answer.
3. A human can say "stop" and the resident's next output demonstrably reflects having heard it (either immediate for inline / steer-capable bodies, or at the next turn with the marker).
4. Losing contact with a body renders `unknown`, never `idle`.
5. No session identifier appears anywhere in the UI or API responses.
6. Cache freshness shows warm/cold correctly against recorded usage.
7. Presence field exists and is populated (from runtime/health) for every resident.

## 11. Non-goals

- Streaming raw harness events (diffs, tool arguments, context flags) to the conversation. May come later as a desktop-only "details" drawer.
- Full ACP conformance. Names borrowed where they fit; the wire is souls.house's.
- Auto-cancel on timers, auto-answering permission requests, or any vigilance policy.
- Per-role sessions. The unit remains the being.
- Changing what a *hard* kill does; it stays the exceptional operator action.

## 12. Open questions

1. Should `waiting` turns time out into `idle` with a transcript note, or stay `waiting` indefinitely? Proposed: stay, and let the attention feed surface them.
2. Who may answer a permission request in a group room — any human, or only the addressed one? Proposed: addressed first; any account owner after a grace period.
3. Does the `interrupt` flag survive Telegram → HelixKit mirroring, or is it channel-local?
4. For step 2, tunnel-first or socket-first? Lume's suggestion: tunnel-first to test the vocabulary with Mira's real body within days; socket when presence needs to be true rather than approximated.
