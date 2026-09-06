# Live Chaos activity in souls.house

**Status:** proposed; for Daniel and Lume to review. No implementation.
**Superseded after Lume's review:** see
[`260906-01c-chaos-lifecycle-visibility-revised-design.md`](260906-01c-chaos-lifecycle-visibility-revised-design.md).
This original is retained so the review's references remain meaningful.
**Investigated:** 2026-09-06, souls.house `fffd2f4`, Chaos `f456ecdf2`.
Both repositories were pulled. souls.house work is confined to `souls-house-1`;
existing untracked design documents in Chaos were left alone.

## Recommendation

Give Chaos an **opt-in, generic activity reporting sink**, driven by the same
typed events its TUI consumes. Give souls.house a **run-scoped callback API**
and a persistent, expandable activity card inside the conversation.

This is an observation channel, not a second conversation channel or a remote
terminal. Show actual progress: preparations, tools starting/finishing, plans,
explicit commentary, retries, completion and lost contact. Do not infer progress
from elapsed time, generate status prose with another model, or send private
reasoning/tool payloads to the browser.

Keep the current message contract: a resident posts a chat reply through the
house API. Chaos's final stdout is **not automatically a chat reply**.

The implementation spans three pieces:

```text
souls.house dispatch creates a run and scoped reporting credentials
    │ POST /trigger (run identity, callback configuration)
    ▼
trigger_shim.py — prepares/resumes an attempt and supervises its lifetime
    │ chaos exec --activity-report-url … --activity-report-token-file …
    ▼
Chaos event queue → safe activity projection → bounded asynchronous HTTP sender
    │                                  shim also reports supervisor state
    ▼
souls.house callback → validate + persist + reduce run state
    │ after commit, revision notification over existing Action Cable
    ▼
chat activity card → fetch persisted snapshot/details; survive refresh/reconnect
```

Ship this for house-triggered conversations first. Design IDs and transport so
a future local/external resident can use them, but do not implement remote
enrolment, Mira integration, mobile approvals or remote control in this release.

## What exists today, and where the information disappears

### Chaos

- `lib/libcontract/ipc/src/protocol/event_msg.rs`: the event queue already has
  turn start/completion/abort, tool begin/end, plans, commentary/message events,
  MCP startup, retries, compaction completion, collaboration and progress.
- `protocol/events_agent.rs`: `TurnProgress` is explicitly approximate liveness,
  **not billing or a percentage complete**. Assistant message events have an
  optional phase; `items.rs` preserves it on typed message items too.
- `sys/exec/fork/src/lib.rs`: exec reads the event queue in `run_event_loop`.
  Bootstrap events and early exits need reporting too; some events are filtered
  before the existing output processor sees them.
- `sys/exec/fork/src/event_processor_with_jsonl_output.rs` and `exec_events.rs`:
  `--json` already emits process/turn/item events, commands, MCP calls, plans and
  final usage. It is not a safe remote-view contract: it includes reasoning,
  command strings, aggregated output and tool payloads; it also drops some
  protocol events and does not preserve message phase in `AgentMessageItem`.
- `lib/libui/chatwidget/events/protocol_dispatch/lifecycle.rs`: the TUI already
  distinguishes active turns, startup and progress. Reuse event semantics, not
  terminal rendering or terminal-title icons.
- `lib/libmisc/session/src/lib.rs`: shared userland SQ/EQ session boundary offers
  a future TUI attachment point. Do not add a second `next_event` consumer:
  observers must receive a tee from the frontend that owns the event stream.
- `sys/kern/kern/src/clamp_bridge.rs`: clamped tool requests go through the
  Chaos tool router. That is useful common ground, but does not prove every
  Claude Code/Antigravity text/progress event has native-provider parity.
  Capability tests, not an assumption, must establish coverage.

### souls.house

- `app/lib/external_agent_response_request.rb` wraps the runtime request in
  `AgentRuntimeInteraction.record_trigger!`, **after** sandbox startup.
- `app/lib/chaos_trigger_client.rb` waits synchronously for the trigger response;
  default runtime timeout is 30 minutes, HTTP read timeout 30 minutes + 30 seconds.
- `agent-runtime/trigger_shim.py#run_chaos` uses `subprocess.run(capture_output=True)`.
  JSONL is parsed after process exit for session identity, output and usage.
  Resume can fall back to a fresh attempt within one house trigger.
- `AgentRuntimeInteraction` already persists trigger history and terminal
  diagnostics, broadcasts `runtime_interactions` refreshes and powers
  `AgentRuntimeActivityCard.svelte`.
- Current `ACTIVE_WINDOW` is 12 minutes. It governs admission/UI activity despite
  the longer runtime timeout. Expiring it is not proof that execution stopped.
- `visible_in_chat_timeline?` hides an interaction if an assistant message by the
  same resident appears in a time window. Posting a progress message can therefore
  hide activity while work is still running. Time-window matching is not identity.
- `ChatsController#runtime_interactions_for_timeline` fetches the latest 20
  interactions and sorts by finish/start time. Completing a run can move its card.
- `as_chat_activity_json` currently exposes stdout/stderr/error text to chat
  viewers. The new safe feed must not quietly retain this diagnostic escape hatch.
- `SyncChannel` already authorizes chat/agent subscriptions using
  `accessible_by?`; use it rather than adding a publicly addressable WebSocket.

## Product experience

One stable activity card per requested run, anchored at its creation time:

```text
Mira · Running a command                          2m 14s
I found the event boundary; checking reconnect behavior next.

▾ Work so far
  ✓ Inspect the current runtime bridge
  → Design the reporting contract
  · Specify the browser changes
  ✓ Read files                         4 operations
  ✓ Apply a patch
  → Run a command                      18s

Activity received 3s ago
```

The text and plan above are illustrative, not model-generated system summaries.
Only show commentary/plan text actually authored for the public activity channel.
Tool labels come from a fixed mapping; without seeing command arguments we cannot
honestly label an arbitrary command “Run tests.”

- Collapsed card: resident, accurate phase, elapsed time, current operation(s),
  optional latest explicit commentary. No fake percent-complete bar.
- Expanded card: bounded plan and chronological tool/status activity, durations,
  simple outcomes. Support overlapping tools, not just a single “current tool.”
- Keep the card visible while replies arrive. On completion collapse it to
  “Finished · 2 replies posted” or “Finished without posting a reply.” Silence
  remains a legitimate resident outcome.
- Separate “Execution failed/timed out” from “Live updates interrupted.”
  A broken reporting connection must not become a fabricated resident failure.
- On mobile, preserve scroll position, do not steal focus or force expansion,
  and do not announce every heartbeat through screen-reader live regions.
- Show a capability-aware fallback for old runtimes: “Working; live activity
  unavailable on this runtime.” Never show an empty panel promising rich updates.
- Status text is plain escaped text. No tool-generated HTML, embedded images,
  automatically fetched URLs or terminal escape sequences.
- Do not show an actionable “Waiting for your approval” when there is no reply
  transport. Current exec sets `ApprovalPolicy::Headless`; preserve its actual
  deny/fail behavior. Surface observed input/approval failures as non-actionable
  explanations, without suggesting a mobile approval is pending.

**Privacy choice proposed for review:** structural events by default; completed
`commentary`-phase text and explicit `PlanUpdate` text enabled for opted-in
house conversation runs, with clear product disclosure that these are shared
with everyone who can read that conversation. No text inferred from absent
phase metadata. Unknown-phase and final-answer text stay out of this feed.
Plan-mode draft prose is not automatically an explicit shared plan.

## Identity and state: avoid conflating session, attempt and run

Extend `AgentRuntimeInteraction` as the existing **house run**, rather than build
a parallel run history:

- `run_id`: random immutable UUID, one user request/dispatch.
- `session_id`: existing logical resident+conversation key; reused across runs.
- `attempt_id`: new UUID for each actual Chaos invocation, including fresh fallback.
- `attempt_number`: coordinator-assigned monotonic integer within the run.
- `chaos_session_id`: Chaos process identity, which may be resumed across runs.
- `turn_id`: actual Chaos turn, when known.
- `operation_id`: tool/plan identity scoped to the attempt.

Never deduplicate on Chaos session ID alone. Never use display names, timestamps
or a supplied conversation ID to decide which run receives a callback.

Add `AgentRuntimeAttempt` for invocation identity/lifecycle and
`AgentRuntimeEvent` for bounded safe activity. Keep usage/transport columns on
the interaction for compatibility. Lifecycle schema version is separate from
the existing accounting `telemetry_schema_version`.

Run execution states:

```text
queued → preparing → running → completed | failed | timed_out | cancelled
                           ↘ outcome_unknown (supervision lost)
```

Reporter health is separate: `connecting`, `live`, `stale`, `unavailable`.
Current activity is separate again: model work, tools, retry, startup, etc.

Authority rules:

1. Rails owns reservation/queue state and dispatch errors before acceptance.
2. The shim owns attempt registration, process exit, timeout and fresh fallback.
3. Chaos owns observed turn/tool progress. A tool failure or stream retry is
   not necessarily a failed turn. A completed turn is not proof the supervised
   process and its shutdown hooks have exited.
4. A lost HTTP response after acceptance records a **transport error**, not an
   immediate execution failure. A terminal supervisor callback may still arrive.
5. Older-attempt events cannot regress the current attempt. Terminal observations
   cannot return to running. `outcome_unknown` may resolve when authoritative
   evidence later arrives; it is not an assertion of failure.
6. Keep final usage authoritative through the existing terminal telemetry path.
   Heartbeats/progress counts are not cost accounting.

Use a shared reducer for terminal HTTP results and supervisor callbacks, so
`record_result!`/`record_error!` cannot overwrite a better execution observation.
Completion callbacks should carry the same bounded terminal telemetry envelope
as the trigger response, idempotently, to recover when the long HTTP response
is lost. Raw diagnostic output is not part of lifecycle event payloads.

## Proposed Chaos contract

Add an invocation-local option family, usable before `exec resume`:

```sh
chaos exec --json \
  --activity-report-url https://souls.house/api/v1/runtime_runs/RUN/events \
  --activity-report-token-file /run/soulshouse/ATTEMPT/activity-token \
  --activity-run-id RUN \
  --activity-attempt-id ATTEMPT \
  --activity-profile conversation \
  ... resume CHAOS_SESSION -
```

Names are proposed, not existing CLI options. `structural` is the generic default
profile; `conversation` adds the explicit shared commentary/plan fields above.

Put the projection and sender in a small userland module/crate (proposed
`lib/libmisc/activity`). Integrate it in exec's existing event consumer and
bootstrap/exit paths. Keep HTTP out of the kernel, model adapters and TUI
rendering code. TUI attachment later can reuse the module without changing the
wire protocol; implementing TUI flags now is not required.

- Options are opt-in and invocation-local, **not** resident configuration or
  persisted resume state. Resuming elsewhere must not silently resume reporting.
- Read the token from a private temporary file, never an argv token, URL query,
  prompt, transcript, config summary or log. Do not serialize it into snapshots.
- Do not propagate reporting credentials/options to child agents or nested
  Chaos invocations. Phase one reports parent-observed delegation begin/end,
  not child transcripts or complete child event trees.
- Observe normalized events before rendering; choose one canonical path for
  message/tool items so typed and legacy duplicate notifications produce one
  activity item. Do not export replayed historical messages on resume.
- Keep `--json` stdout and accounting behavior backwards compatible. A separate
  safe contract avoids breaking existing JSONL consumers.

### V1 event allowlist

| Activity | Source/evidence | Public fields |
| --- | --- | --- |
| `attempt.observed` | bootstrap/configured | attempt/session IDs, capabilities, model identifier |
| `turn.started` / `turn.finished` | turn start/complete/abort | turn ID, outcome code |
| `tool.started` / `tool.finished` | exec, patch, MCP, web, image, canonical tool events | operation ID, fixed category/label, outcome, duration, bounded counts |
| `plan.updated` | explicit plan tool | stable step IDs, bounded text, status |
| `commentary.completed` | canonical assistant item with explicit commentary phase | item ID, bounded text |
| `retry.scheduled` | actual recoverable stream/retry evidence | stable reason code, delay/attempt only if known |
| `context.compacted` | existing completed-compaction event | completion marker only |
| `delegation.started` / `delegation.finished` | parent collaboration events | operation ID, outcome, bounded child count |
| `heartbeat` / `snapshot` | reporter timer/projection | current safe state, last source activity time, dropped-detail counters |

Do not advertise “Compacting…” until a real compaction-start signal exists.
If a generic tool lacks matched begin/end instrumentation, add it at the
canonical tool execution boundary; do not parse shell output to invent it.
Report capabilities so partial implementations still tell the truth.

**Never export:** raw/summary reasoning text, raw response items, prompts,
system/developer instructions, history replay, tool arguments/results, command
strings, command output, patch contents, full filesystem paths, search queries,
MCP endpoint names, environment, credentials, raw exceptions or hook output.
MCP tool names require a safe mapping; unknown tools use “Use an external tool.”

Public commentary and plan text can themselves contain sensitive material.
Truncation/regexes are not a confidentiality guarantee. The resident must know
this is a shared channel; structural-only remains available. Test canary-secret
exclusion in non-public event fields, rather than claiming perfect prose redaction.

### Delivery and envelope

Batch example (illustrative IDs):

```json
{
  "schema_version": 1,
  "batch_id": "uuid",
  "run_id": "uuid",
  "attempt_id": "uuid",
  "events": [
    {
      "seq": 17,
      "occurred_at": "2026-09-06T06:00:00.000Z",
      "type": "tool.started",
      "turn_id": "uuid",
      "operation_id": "call-7",
      "data": { "category": "command", "label": "Run a command" }
    }
  ],
  "snapshot": {
    "through_seq": 17,
    "turn_state": "running",
    "active_operations": [
      { "operation_id": "call-7", "category": "command" }
    ],
    "detail_dropped": 0
  }
}
```

Sequence is monotonic **per attempt**, not per persisted Chaos session.
Retry the identical batch/sequence IDs. No exactly-once delivery claim:
at-least-once delivery attempts with idempotent consumption and explicitly
bounded, potentially incomplete detail.

Initial limits to validate under load:

- flush structural changes within 250–500ms; heartbeat every 10s;
- at most 50 events / 64 KiB per request, 4 KiB per text field;
- bounded sender memory (1 MiB), bounded in-flight requests (one per sender);
- bounded snapshot cardinality (initially 100 plan steps / 256 active operation
  summaries, with omitted counts rather than an oversized request);
- 2s connect/5s total request deadline, exponential backoff with jitter capped
  at 30s; honor bounded `Retry-After`; no HTTP redirects;
- retry network errors, 429 and 5xx; stop on revoked/expired credentials;
  schema/payload errors disable the reporter with a sanitized local warning;
- keep the latest state snapshot and terminal state outside the droppable
  detail queue. Coalesce heartbeats and drop oldest detail with explicit counts
  under pressure. Never block agent execution on network delivery;
- bounded 2s shutdown flush; a killed reporter can lose events. The shim's
  independent terminal report and the UI's stale state cover that uncertainty.

This is not a durable transcript replication service. If long offline replay
becomes a requirement for external residents, add a separately reviewed encrypted,
size-limited outbox; do not smuggle a second journal into phase one.

## Shim and souls.house integration

### Dispatch and supervision

Introduce a shared conversation-dispatch service which reserves the interaction
and enqueues the job transactionally (using the repository's supported
after-commit job behavior). Lock the logical agent+chat dispatch key to prevent
two clicks racing through the current read-only “already active?” check.
Jobs receive the run ID; retries reuse it rather than creating new runs.
Give unaccepted queued work a dispatch deadline; expiring it invalidates the run
before any late job may start. A job must recheck reservation state on entry.
All-agents requests reserve/report each member consistently and preserve current
sequential semantics. Skipped/ineligible members still never fabricate messages.

Create the run **before** sandbox startup so queued/preparing work is visible.
Do not attach this callback to every heartbeat, orientation or Telegram trigger
yet: these can lack a chat or have a different audience. Preserve their existing
telemetry. Use `trigger_kind`/scope for a later explicit extension.

Change `record_trigger!` to yield/use the interaction rather than hiding it from
the request block. Add an optional `activity` envelope to `ChaosTriggerClient`.
The shim obtains the app origin from trusted runtime configuration; reject
callback origins that differ from it. Do not accept arbitrary user-supplied
reporting URLs or pass reporting settings into prompt text.

The shim registers a fresh attempt before each Chaos invocation; resume fallback
registers attempt 2, it does not reuse attempt 1's sequence or terminal state.
Gate flags on an advertised activity capability from the installed Chaos binary,
cached per binary version. Do not discover unsupported flags by running the
resident twice. Extend the shim health/capability response and cover old images.

Use a supervised `Popen`/`communicate` path (preserving current terminal JSONL
parsing) to track process lifetime, send supervisor heartbeats and terminate the
owned process group on timeout. No streaming stdout parser is required for
the proposed direct Chaos HTTP sink. Ensure descendants cannot survive a timeout
unnoticed; if termination cannot be confirmed, report `outcome_unknown`.
The supervisor token stays in the shim; only an attempt-scoped event token goes
to Chaos. Terminal execution reports use the supervisor route/credential.

Make `/trigger` idempotent on `run_id`: a retried transport request returns
the same accepted/running/result identity, not a second invocation. Persist a
bounded run ledger beside the existing session mapping for restart awareness;
after shim restart, an uncertain prior process must be reconciled, never blindly
re-executed. Do not add automatic retries of resident work as part of reporting.

### Reporting authentication

Proposed routes:

- `POST /api/v1/runtime_runs/:run_id/attempts` — shim registers attempt;
- `POST /api/v1/runtime_runs/:run_id/events` — Chaos event batches;
- `POST /api/v1/runtime_runs/:run_id/status` — supervisor heartbeat/result.

Use dedicated purpose-scoped capability authentication, **not** the current
general outbound resident API token. Store token digests and explicit scope,
run/attempt binding and expiry. Event capability cannot create messages, execute
tools, register another run/attempt or claim supervisor completion.

The run is already bound to account, resident and optional chat. Ignore/reject
foreign identifiers; authorization comes from the stored binding. Validate
runtime eligibility and revocation. Stop accepting live reports when the run's
sharing authorization is revoked; retain previously authorized history under
normal chat access rules. Deleting a chat must revoke reporting, not leave a
nullified interaction accepting content forever.

Token lifetime covers the configured execution deadline plus a small terminal
delivery grace period (proposed 10 minutes), not a fixed 12-minute assumption.
No token extension for an arbitrary request body. Duplicate terminal retries
can acknowledge the recorded result during grace without reopening execution.
Rate-limit by capability/run and IP; apply body limits before parsing.
Use constant-time token checks and filter tokens/activity credentials from logs.

HTTPS only in production. Local HTTP exceptions must match the explicit
instance-local configured app URL; never use another clone's endpoint/credentials.
No redirects, URL userinfo or implicit forwarding of bearer headers.

**Trust boundary:** this authenticates an authorized reporter, not a tamper-proof
resident. A same-UID resident with broad shell/filesystem access may inspect its
own process/files. Token files are credential hygiene, not isolation against
that resident. Keep supervisor secrets out of child environments, and do not use
activity reports to authorize privileged actions.

### Persistence, ordering and reconciliation

Store safe event fields only. Unique `(attempt_id, seq)` and batch identity
constraints make retries idempotent; a conflicting duplicate payload is rejected.
Unknown schema versions are rejected explicitly. Unknown event types within a
supported version may be ignored with an explicit acknowledgement/warning; never
stored as arbitrary JSON and later rendered.

Serialize updates under the run row lock: atomically append validated events,
apply the reducer and increment a run revision. Acknowledge after commit.
Sequence ordering governs attempt projection, not wall clocks. Older snapshots
cannot overwrite newer state; newer-attempt registration fences old-attempt
updates from the current view. Late events may fill historical detail only.

Return acknowledged batch identity, not a misleading contiguous global sequence.
Snapshot `through_seq` and explicit dropped-detail counts permit convergence when
detail is missing. Persist heartbeat timestamps/current projection without one
history row per heartbeat. Server receive time governs freshness; sender time is
display metadata, not authorization or timeout authority.

Proposed health thresholds: stale after 30s without reports, lost contact after
90s. Neither proves the process died. Dispatch reservation remains held while
supervision indicates execution may continue. Replace the 12-minute admission
window with supervisor lease/deadline reconciliation; expiry changes to unknown,
not “safe to run again.” Reconcile with the shim's run-status ledger before
releasing/retrying an uncertain run. For all-agents chains, stop the chain with
a visible “Incomplete: one resident's execution could not be confirmed” outcome;
identify the remaining residents as not started. Do not silently continue in
parallel, hold an invisible queue forever, or duplicate the uncertain execution.
A later explicit request still has to pass each resident's run-admission check.

Keep bounded detail: proposed 2,000 events / 2 MiB per run and 30-day retention
for detail, with current/final summary retained with the interaction. Sender and
server truncation must both be visible. Cleanup must spare active runs and
preserve enough identity/tombstone state to reject old duplicates. Chat deletion
and account retention policy must cover attempts/events too.

### Replies, browser updates and access control

Add optional `runtime_interaction_id` to `Message`. The post-message helper sends
the run ID from an invocation-local environment variable for JSON and multipart
requests. The message API validates matching resident/account/chat and a valid
run posting window. A run ID alone grants no posting authority. Normal API
message authentication and conversation membership still apply.

Messages can arrive before the trigger returns or after turn completion but
before shutdown. Multiple messages can belong to one run. Do not retrospectively
assign historical messages by time window; show legacy association as unknown.
If an old/unmodified helper omits correlation, don't falsely say “no reply” when
correlation is incomplete. Posting to another chat must not attach this run ID.

For new activity cards, remove `visible_in_chat_timeline?`'s time-window hiding.
Render by stable run creation position, retaining active runs even outside the
latest-20 historical page. Completed activity can collapse alongside linked
replies, never become a duplicate assistant message.

Use existing chat subscriptions for a lightweight
`runtime_activity_changed { run_id, revision }` invalidation. Coalesce to at most
one notification per run per second; flush terminal changes immediately.
Do not reload all messages/agent debug props for every heartbeat.
Authenticated chat-scoped snapshot/detail endpoints return safe projections
with pagination. Initial load, reconnect and foreground return fetch fresh state;
a low-frequency fallback poll while active covers dropped notifications.
Clients discard stale fetch responses by run revision.

Move raw stdout/stderr/full exceptions out of the regular chat activity payload
and UI, not merely behind a collapsed `<details>`. Preserve diagnostic history
and expose it only through an explicitly authorized owner/admin diagnostic view.
Safe activity uses the same chat-read policy as conversation messages. HTTP
reads recheck access; review existing Cable revocation behavior and disconnect
revoked viewers or use scoped invalidations that carry no content.

## Alternatives considered

1. **Stream existing `--json` in the Python shim.** Fastest structural prototype;
   no new HTTP client in Chaos. But raw JSONL is broad/private, loses phase and
   some liveness events, and would make the shim maintain a second semantic
   projection. Reasonable fallback if we want an intentionally smaller first
   slice, not the preferred reusable contract.
2. **Safe JSONL/FD sink in Chaos, HTTP relay in the shim.** Good transport
   separation; also a sensible later transport for the same projector. It adds
   pipe draining/relay/backpressure work now and needs another launcher for a
   future local TUI resident. Direct opt-in HTTP matches the proposed use case.
3. **Lifecycle hooks.** Useful for selected integrations, insufficient for all
   tools/progress; avoid per-event subprocess/network work and touching identity
   hooks merely to animate a UI.
4. **Raw SSE/terminal forwarding to the browser.** Couples browser lifetime to
   execution, loses refresh history and exposes excessive content. Not needed.
5. **Full bidirectional remote Chaos session now.** Ultimately interesting,
   but needs distinct authorization, resumable control, approval/input semantics,
   interruption and multi-viewer conflict handling. Observation is a useful
   independently shippable step, not a promise those controls already exist.

## Implementation sequence and verification gates

1. **Agree contract/privacy and fixtures.** Shared versioned JSON fixtures for
   native/clamped traces; exact IDs, state precedence, bounds and redaction.
   Implement projector tests before networking.
2. **Rails foundations behind a flag.** Run reservation, attempts/events,
   restricted callbacks, reducer, bounded read API, reconciliation and
   message correlation. Existing runtimes continue their old path.
3. **Chaos opt-in observer/sender.** CLI plumbing, safe projection, bootstrap/
   exit handling, capability advertisement and nonblocking transport. No default
   reporting and no TUI behavior change.
4. **Shim integration.** Trusted configuration, capability gating, scoped tokens,
   attempt identity, idempotent acceptance, supervision/timeout/reconciliation
   and terminal telemetry recovery. Preserve session-resume accounting.
5. **Activity UI.** Structural events first; explicit commentary/plans under the
   agreed sharing profile. Reconnect, retention, stable anchoring and diagnostics
   access changes included—not postponed until after “live” ships.
6. **Synthetic end-to-end validation, then opt-in rollout.** Deploy compatible
   Rails first, then a pinned Chaos runtime image, then enable selected synthetic
   runs. No resident wake merely to demonstrate progress.

Suggested file map:

| Repository | Main changes |
| --- | --- |
| Chaos | `sys/exec/fork/src/cli.rs`, `lib.rs`; proposed `lib/libmisc/activity`; protocol/tool instrumentation only for demonstrated missing events; exec CLI/projector/sender tests |
| souls.house | `AgentRuntimeInteraction`; new attempt/event models and reducer/dispatch services; additive migrations; dedicated callback/read controllers; `ChaosTriggerClient`; conversation/all-agent job paths |
| runtime | `trigger_shim.py`, `soulshouse-post-message`, runtime capability/docs/build pin |
| browser | `AgentRuntimeActivityCard.svelte`, chat timeline assembly, cable/sync refresh handling, new activity tests |

Required tests:

- Projection rejects private reasoning, prompts, args/results, shell output,
  secrets and unknown-phase text; typed/legacy duplicates and resume replay.
- Native and clamped fake traces establish actual tool/commentary/plan coverage;
  unsupported capabilities remain explicitly absent.
- Sender: slow/dead endpoint, duplicate delivery, 429, 5xx, redirects, revocation,
  schema mismatch, queue overflow and shutdown. Execution remains responsive.
- Rails: cross-account/chat/agent/attempt spoofing, expired/revoked tokens,
  malformed/oversized batches, conflicting duplicates, out-of-order batches,
  old-attempt fencing, concurrent callbacks/results and deleted/revoked chats.
- Shim: queue/preparation failure, long quiet command, timeout/process-group
  cleanup, resume fallback, response lost after successful execution, restart
  with uncertain process, duplicate trigger, old Chaos binary and OAuth modes.
- Reply correlation: JSON/uploads, multiple replies, no reply, reply mid-run,
  missing correlation and cross-chat rejection.
- Browser: reload/reconnect/out-of-order fetch, concurrent residents/tools,
  more than 20 runs, stable scroll/anchor, mobile/accessibility, safe output and
  no duplicate messages. Inject a reporting outage while execution finishes.
- Retention/volume test: long tool-heavy synthetic run, bounded data and broadcast
  rate; stale UI does not enable duplicate work.

Use instance-one fake/local endpoints and normal owned test runners. Paid
synthetic provider smokes, if needed, stay within Daniel's authorized <$2
estimate; no real identity content or wakes. Re-run both repositories' relevant
suites and the house full Rails/Vitest/browser suites before integration.

Rollback: disable reporting/profile flags first; old runtimes still work.
Keep additive schema/history. Stop live indicators gracefully rather than
deleting runs or reenabling inline execution. No billing migration.

## Decisions requested from Daniel and Lume

1. **Approve direct, generic Chaos reporting** with a safe public projection,
   rather than a Python parser of raw JSONL?
2. **Approve the sharing boundary:** structural by default; explicit commentary
   and plan text for opted-in conversation runs; no reasoning/raw tool payloads?
3. **Approve read-only phase one:** no Stop/Approve/Answer controls yet, and
   actual replies still posted through the house API?
4. Review state authority, reply correlation and unknown-execution behavior
   particularly closely: these are correctness constraints, not UI polish.

My recommendation is yes to the first three, with the failure/reconnect/privacy
work included in the initial release. That gives us a trustworthy window into
work now, and a transport/session foundation for external residents later.
