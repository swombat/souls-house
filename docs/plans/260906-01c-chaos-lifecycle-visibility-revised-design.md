# Live activity: smaller first release

**Status:** approved for implementation by Daniel, 2026-09-06. Supersedes 01a;
incorporates Lume's 01b review and the persistent-card clarification below.
**Source bases:** souls.house `fffd2f4`, Chaos `f456ecdf2`.

## Decision

Keep the run/attempt model, safe activity feed and execution/reporter distinction.
**Stream Chaos's existing JSONL through the Python shim.** The first Chaos change
is optional `phase` and `canonical` metadata on JSONL `AgentMessageItem`,
not a new HTTP subsystem.

```text
Rails reserves run before sandbox startup
  → shim starts supervised chaos exec --json
  → reads JSONL continuously → allowlisted projection → bounded HTTP reporter
  → one Rails callback → attempt/events + reducer
  → revision invalidation on existing chat subscription → activity card
```

Reporting is normal behavior for house-launched conversations, not an extra
user toggle. No Chaos reporting switch is needed in this version. Standalone
Chaos does not transmit anything. **Narration sharing**, separately, is the
resident's choice and is disclosed to everyone who can read the conversation.

This version is read-only. Replies still come through `soulshouse-post-message`,
not automatically from Chaos stdout. No remote approvals, input or Stop button,
Mira enrolment, TUI attachment or external-resident infrastructure yet.

## What the review changed

- Removed the proposed Chaos sender/crate/CLI, three callback routes, child
  reporting credentials, durable trigger ledger and scheduled detail retention.
- Made provider/transport capability differences an explicit product behavior.
- Kept only truthful phase/operation labels; a heartbeat means the supervised
  process exists, **not** that the model is generating or making useful progress.
- Specified explicit reply-link precedence across activity, costs and refreshes.
- Moved heartbeat/projection writes away from interaction refresh callbacks.
- Added a finite reservation release rule, with its uncertainty made explicit.
- Named actual after-commit enqueue behavior and preserved the existing
  transcript-cursor and session-busy semantics.

Two precision corrections to the review:

1. `responses.rs:656` is inside `#[cfg(test)]`, not a production phase assignment.
   Production at `:260-263` deserializes `ResponseItem`, preserving an upstream
   phase when supplied. The provider-split conclusion stands, but not a guarantee
   that every OpenAI Responses message is classified.
2. The shim's session lock rejects **concurrent** duplicate triggers, not a
   repeat after completion. Deferring idempotency is reasonable only while we
   explicitly prohibit automatic retry of ambiguous accepted work.

## Chaos: additive JSONL change only

In `sys/exec/fork/src/exec_events.rs`, add optional `phase` to
`AgentMessageItem`, defaulting to absent on deserialization. Populate it at both
construction sites in `event_processor_with_jsonl_output.rs`. Test explicit
commentary, final answer and missing phase; retain existing stdout/usage behavior.
Update affected Rust constructors/fixtures and generated types as required.
Add an optional `canonical` boolean alongside phase: typed items set true,
legacy events false, old input defaults to absent. This lets the shim suppress
legacy commentary echoes without guessing from text or generated item IDs.

No adapter heuristics. Current Anthropic, Chat Completions, LSD and adapter
construction paths inspected supply `phase: None`; neither inspected clamp
path supplies explicit commentary phase. OpenAI Responses can preserve it.
Do not interpret “text before a tool” as consent or phase.

Capabilities are a combination of **adapter/transport support and observed
schema**, not just binary version or a model's marketing name:

- tools/turns: render supported JSONL items on old and new binaries;
- narration: adapter supports phase, JSONL preserves it, the item explicitly
  says commentary, and the resident allows sharing;
- missing phase: omit text, never guess. A supported adapter may emit none.
- unsupported adapter: “Narration isn't available from this provider connection.”
- old/unknown JSONL schema: “No shared working narration received.” Absence of
  a classified message alone does not prove the binary lacks the field.
- resident disabled: “Working narration isn't shared.” Distinguish this from
  technical unavailability without presenting it as a defect.

The shim knows provider/auth/clamp configuration; use a small tested capability
matrix plus optional-field parsing. No new Chaos capability CLI is necessary.
The matrix is conservative for unknown providers/versions.

Persist a resident-controlled narration-sharing preference, default off. Set it
through an authenticated resident self-settings action, not the human owner edit
form or an inference from model prose. Snapshot consent into dispatch; revocation
also stops server acceptance of new narration for active runs and clears pending
sender narration on the next callback acknowledgement. Previously shared history
follows normal conversation retention; revocation is not retrospective erasure.

`PlanItemArg` has text and status, not stable step IDs. If we display plans,
replace the bounded whole plan snapshot on update; array positions are rendering
keys within that snapshot, not durable step identities. Plan text shares the
resident's narration permission. A plan tool remains usable even on providers
without commentary phase.

## Shim: observe, project, report

Replace `subprocess.run` with a supervised `Popen` path:

- Drain stdout and stderr concurrently so either pipe cannot block execution.
  Consume JSONL as lines become complete. Keep the existing final session/usage
  extraction and bounded diagnostic results; don't buffer a second full trace.
  Cap a buffered line at 1 MiB; discard oversized lines through the next newline
  with a visible detail-loss counter, then resume parsing subsequent events.
- Project before enqueueing HTTP work. A separate bounded sender must never
  block pipe drainage or the resident on a slow server.
- Send a heartbeat every 10 seconds while the owned process is observed alive.
  Preserve event sequence separately from report receipt. Long quiet commands remain “Running a
  command”; silence is not a made-up generating state.
- On exit/timeout, report supervisor outcome and the same versioned terminal
  allowlisted accounting subset of the HTTP response's telemetry envelope.
  File paths and diagnostic bodies do not enter the reporting queue.
  Process exit is distinct from
  `turn.completed`; hooks/shutdown can still be in progress.
- Terminate and reap the owned process group on timeout. Report unknown if
  termination cannot be established. Never kill unrelated processes/containers.
- On resume→fresh fallback create a new attempt ID/ordinal, reset that attempt's
  sequence, and retain the failed attempt in history.

Use **one run-scoped, purpose-limited callback token, held only by the shim**.
This is a slight simplification of 01b's “attempt-scoped” token: the shim must
report both resume and fallback under the same accepted trigger. Limit it to
one pre-created run and the current maximum two attempts. Each event is still
attempt-bound. Do not call a token authorizing two attempts “attempt-scoped.”
No token goes into Chaos argv, prompt, tool environment or JSONL.

Callback URL comes from the trusted `SOULSHOUSE_ACTIVITY_ORIGIN` (falling back
to the runtime app origin locally) and Rails-supplied run
path, never arbitrary resident input. HTTPS in production; only the configured
instance-one origin may use HTTP locally. No redirects or bearer forwarding.
Strip callback credentials from child environments and request logs.

One route: `POST /api/v1/runtime_runs/:run_id/events`. It accepts a versioned batch
of strict allowlisted events including attempt-start, heartbeat and supervisor
finish. Run/account/resident/chat binding comes from the stored token/run, not
supplied IDs. Store token digest, expiry and revocation; reject foreign,
deprecated/revoked or deleted-chat reports. Token grants no message/tool rights.
Same-UID residents are not a tamper-proof boundary; these are observations, not
proofs authorizing privileged behavior.

### Public payload and bounds

Envelope: `schema_version`, `batch_id`, `run_id`, `attempt_id`, `attempt_number`,
`events[{seq, type, data}]`. Operation identity lives inside tool event data.
Heartbeat data carries a bounded current-operation snapshot and omitted-detail
count, repairing lost tool finishes without inventing missing history.
Server receipt times are not represented as exact execution timestamps.
The first batch registers its attempt under the run lock; only ordinals 1 then
2 are allowed, and attempt 2 requires an explicit fallback transition.

Include: turn start/end, tool start/end with fixed category labels/outcomes,
parent-observed delegation state, retries where identifiable, explicit shared
commentary, optional shared plan snapshot, heartbeat and supervisor outcome.
Keep active operations keyed by attempt/item ID so parallel tools coexist.

Exclude: reasoning and reasoning summaries, prompts/history, raw response items,
tool args/results, commands/output, diffs/paths, search queries, MCP endpoints,
raw errors and secrets. Unknown tools become “Use an external tool.” Unknown
JSONL types are ignored, not forwarded. Do not claim compaction/startup detail
the current JSONL does not emit. Ordinary JSONL errors can represent retryable
stream errors; supervisor outcome, not any `error` line, settles execution.

Only completed explicitly phased commentary is shared, not inferred narration
or final-answer text. Test canonical/legacy duplicate message paths; do not
deduplicate solely by text, which may legitimately repeat. If stable identity
is missing, prefer the canonical typed item path and suppress the legacy echo.
Do not export resume `initial_messages`; current exec ignores that replay in
the event loop. Any future bootstrap observer must preserve this exclusion.

Initial caps: 50 events/64 KiB per batch, 4 KiB per text field, 100 plan steps,
64 sender active-operation summaries (256 reducer maximum); omitted counts when exceeded. Sender queue
1 MiB, one HTTP request in flight, changes flushed within 500ms, 10s heartbeat.
Timeout HTTP at 5s; bounded exponential backoff/jitter for network/429/5xx.
Stop on authentication/schema failure with a sanitized local warning.
Drop oldest detail under pressure, retaining control events/terminal outcome
and recovering current operations on the next heartbeat,
and visible dropped counts. Bounded 2s final flush. This is not durable replay.

## Rails: run ownership, persistence and release

Reuse `AgentRuntimeInteraction` as the run. Add `AgentRuntimeAttempt` and
`AgentRuntimeEvent`; random run/attempt IDs, unique `(attempt_id, seq)`, immutable
attempt ordinal. Sequence is per attempt; a persisted Chaos session may be
resumed across many runs. Retry identical batch IDs/payloads; conflicting
duplicates are rejected. No exactly-once delivery claim.

Reserve before Docker startup under the **same logical key** the shim locks:
`"#{agent.uuid}-#{chat.id}"`. A database row lock on the chat during reservation
can serialize the active-run query/create (slightly broader, but conventional).
Admission holds the chat lock; release additionally locks/reloads each run,
also fencing concurrent reports and dispatch claims. Enqueue from an explicit
`after_create_commit` callback for a dispatchable conversation interaction, using
`perform_later`; do not assume a configured `enqueue_after_transaction_commit`.
Jobs receive/recheck the run and atomically claim it once before starting.
Bound unaccepted queue/preparation time; expired jobs must not start late.

No automatic retry after a trigger may have been accepted. A job re-delivery
does not re-invoke an already claimed run. Enqueue failure leaves a visible
unaccepted run that can expire; never pretend DB+job delivery is exactly-once.
Keep the shim's per-session lock. Preserve 409 `already_running` as **busy**,
not a generic resident failure. Durable `/trigger` idempotency is deferred.

Under the run lock, append safe events, apply attempt-fenced projection and
increment revision atomically. Acknowledge only after commit. Older attempt/
sequence data may fill history, never regress live state. Use server receive
time for freshness, not sender timestamps.

**Split existing broadcast callbacks explicitly.** Heartbeat timestamps,
projection and live revision belong on the attempt; no automatic Inertia
refresh callback there. Emit one coalesced, content-free chat invalidation per
run/second, terminal immediately. Interaction create/terminal transitions keep
the necessary existing agent/chat/cost refreshes; remove the “every update”
fan-out behavior for new lifecycle writes.

Execution: queued/preparing/running → completed/failed/timed_out/cancelled, or
`outcome_unknown`. Reporter: connecting/live/stale/unavailable. Tool failure
is not necessarily run failure. A posted reply is not completion.

**Finite release rule — proposed initial values:**

- stale after 30s, lost contact after 90s; neither releases execution immediately;
- send the shim an absolute execution deadline. Budget for the current maximum
  two invocations (up to twice `runtime_timeout_secs`, plus bounded startup),
  rather than pretending the HTTP client's shorter deadline ends both attempts;
- enforce remaining time across attempts; callbacks cannot extend that deadline;
- if deadline has passed **and** supervision has been unreachable/unknown for
  10 continuous minutes, release admission under the lock, record
  `outcome_unknown`/release reason, and keep the card visible;
- reservation reconciliation must run on admission/read as well as any periodic
  maintenance, so a dead worker cannot leave an immortal reservation;
- no automatic rerun. A fresh user request can proceed after release with a
  clear warning that the previous outcome was unconfirmed. A reachable shim
  that remains busy must still reject it. Late callbacks can resolve the old
  record only; never mutate the new run's admission/state.

This is an **availability policy, not proof of process death**. A partitioned or
orphaned process might still act. Zero overlap would require confirmed termination
or enforceable execution fencing, not just a longer timeout. This residual risk
and the proposed release interval need explicit review; we must not promise
both indefinite partition tolerance and guaranteed no duplicate execution.
For all-agents requests, unknown execution stops the chain and visibly says
which remaining members were not started; no new chain scheduler in this phase.

Terminal HTTP response and callback share a reducer. Preserve actual HTTP
transport status separately: callback completion must **not** invent 2xx or
make `prior_cursor_message_id` eligible. Keep its existing actual-success filter
until a separately designed delivery acknowledgement exists. Conservative
re-sending of context is preferable to silently skipping it.
Terminal callback telemetry can complete usage accounting without changing that
cursor predicate. An ambiguous response remains a transport error, not a
fabricated execution failure.

Cap persisted detail at 2,000 events/2 MiB per run; expose the most recent 100
stored events per card, with a truncation notice. Older stored detail pagination
is a follow-up, not an unbounded initial payload. Keep final snapshot and
omission counters outside detail eviction. No scheduled 30-day retention job
now. Lifecycle rows obey account/chat deletion rules, and reporting is revoked
on deletion. Bound heartbeat writes without storing one event row per heartbeat.

## Replies, costs and the card

Add optional `Message#runtime_interaction_id`. The post helper sends a run ID
from an invocation-local environment variable for JSON and multipart. The API
still authenticates the resident and validates account/chat/run identity and
posting window. A run ID alone grants nothing. Cross-chat posting must omit
this run link. Multiple replies can link to one run.

One precedence rule across all consumers:

1. **Validated explicit link wins.** It must not also participate in temporal
   matching to another run.
2. Only unlinked historical/legacy messages may use the existing conservative
   time-window heuristic. Do not backfill guessed explicit links.
3. Update `InteractionCostsByMessage`, `obvious_wake_response_chat`, activity
   reply counts and related refresh logic together. Nil-chat wake runs keep
   their unambiguous legacy fallback.
4. Full run cost is counted once, not once per linked reply. Put the run's cost
   on one deterministic linked reply (earliest by creation time then ID);
   pagination must not choose a new recipient. Other replies retain the explicit
   association without repeating the charge; per-reply run-detail links follow
   the initial card release.
5. When a helper omits correlation, use “No linked reply”/association unknown
   rather than asserting the resident posted nothing.

Remove the temporal `visible_in_chat_timeline?` hide. Fetch active runs separately
from the historical latest-20 slice; no filtering-after-limit slot loss.
Anchor cards at creation time, not completion. Replies do not remove active
cards. Completed cards collapse to outcome/duration/linked-reply count.
They **never disappear merely because a reply was posted or execution ended**.
Completion automatically minimises the card to a compact summary; clicking or
keyboard-activating that summary expands the retained activity again. Users can
also minimise/expand while work is running. Reloaded completed cards start
minimised. The summary remains in the conversation at its original position.

Remove stdout/stderr/raw exceptions from **chat-viewer serialization**, not just
the visible template. Retain diagnostics only in explicitly authorized
owner/admin views. Safe activity follows chat-read permissions.

UI: resident, actual phase, elapsed, active tool categories, expandable bounded
history/plan, optional consented narration, truthful provider fallback. Distinguish
live updates interrupted, busy, failed and outcome unknown. No fake percentages.
Preserve mobile scroll/focus and avoid screen-reader heartbeat spam.

Use existing authorized `Chat:` subscription for `{run_id, revision}`
invalidations. Fetch an authenticated chat-scoped safe snapshot/details;
coalesce requests and ignore older revisions. Initial load, reconnect and
foreground return refetch; slow polling while active covers missed notices.
Check revocation on HTTP reads; invalidations must contain no activity content.

## Delivery order and tests

1. Rails run reservation before startup; remove temporal hiding/raw diagnostics.
2. Attempts/events/reducer, one callback token/route and lightweight invalidation.
3. Shim streaming projection, heartbeat and terminal report.
4. Explicit reply correlation, consistent costs and basic live card.
5. Additive Chaos phase propagation; consented narration with adapter-aware
   fallback. Optional whole-plan snapshots, no new stable step instrumentation.

Acceptance tests cover:

- old/new JSONL, OpenAI Responses phase/missing phase, Anthropic/clamped unknown
  phase, tool concurrency, duplicate message events and replay exclusion;
- canary secrets in every non-public field; valid sharing on/off and safe
  rendering; bounded queue/lines/batches/history under tool-heavy output;
- concurrent dispatch, job re-delivery, busy409, resume fallback, timeout/reaping,
  transport response loss, finite lease release and late old-run completion;
- callback replay/conflicts, attempt fencing, cross-account/chat spoofing,
  revocation, expired credentials and stopped reporting without stopping work;
- no heartbeat broadcast fan-out, reconnect/reload, stable mobile timeline,
  active runs beyond20, explicit/legacy/cross-chat reply links and cost counted
  once, including pagination and nil-chat wakes.

Deploy additive Rails behind a rollout flag, compatible shim, then pinned Chaos
with optional phase; enable synthetic runs before residents. Structural reporting
becomes the normal house behavior. Rollback disables reporting, not resident
execution or preserved history. Test locally in instance1 with owned runners;
no resident wakes. Relevant Chaos tests plus Rails/Vitest/browser suites before
integration.

Deferred: Chaos-native sender (evaluate existing `lib/libtrace/snitch` HTTP/
TLS/retry infrastructure first, without mixing public activity into OTLP billing
telemetry), TUI/external attachment, remote control, trigger ledger/idempotency,
stable plan-step instrumentation, scheduled detail retention and broader
wake/Telegram reporting.

## Approved direction

1. Approve the streaming-shim scope and small additive Chaos change?
2. Approve resident-owned narration consent, provider-labelled absence and
   structural reporting as normal house behavior?
3. Approve the finite unknown-outcome release policy, including its explicit
   residual overlap risk, or require confirmed termination/manual release?

Implement the streaming-shim design and bounded release without automatic retry,
with explicit unknown-outcome presentation. This first release is intentionally
less rich than the TUI; it does not introduce raw reasoning/tool-output sharing.
