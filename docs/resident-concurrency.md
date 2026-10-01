# Asynchronous resident turns

New installations explicitly choose **off** in `config/house.env.example`.
Deploying this code does not opt a running house into it. Set `SOULSHOUSE_ASYNC_TURNS=1` on Rails only after the runtime fleet
supports `/turns/:id` and the canary below passes. Do not change a resident's
runtime while it has an active turn.

The Kamal template requires `SOULSHOUSE_ASYNC_TURNS` to be exactly `0` or `1`
and forwards it to both web and job roles. Persist the chosen value in the
installation's gitignored `config/house.env` on **every deployment checkout**;
`bin/kamal` loads it without a shell export. A missing/invalid value fails
configuration rendering instead of silently reverting an enabled house to the
synchronous path. Existing installations must record their current choice before
the next deployment. Do not change `1` back to `0` without the drain below.

## Ownership

Rails persists a `ResidentTurn` attached to the existing interaction, containing
an encrypted submission payload and a stable dispatch UUID. The producer job
returns after durable queueing. Conversation, Telegram, scheduled wake, memory
aggregation, orientation and safeguard-offer requests all use this gate.

An installation-wide PostgreSQL transaction advisory lock serializes admission;
the partial unique index also prevents two admitted turns for the same session.
Starting, running **and unknown** turns count against `Setting.resident_turn_limit`
(default 50). This is one host's installation, not distributed multi-host
scheduling. For multiple execution hosts, introduce explicit host placement
before treating the setting as a per-host limit.

Admission picks the resident least recently admitted, then their oldest eligible
request. Idle capacity can be borrowed by one resident. Fairness applies when
slots become available; it does not preempt current work. There is no separate
interactive priority tier yet. A paused/disabled resident or removed conversation
membership cannot start a queued turn.

The dedicated `resident_dispatch` Solid Queue pool runs short HTTP submission and
reconciliation jobs. Ordinary default/background jobs keep their own worker pool.
Every ten seconds a recurring dispatcher repairs lost dispatch/poll jobs. Local
development can run `ResidentTurnDispatchJob.perform_now` explicitly.

The runtime accepts a UUID into a private SQLite ledger on the **persistent Chaos
volume**, then supervises execution independently of the HTTP request. Repeating
that UUID and identical payload never starts another execution; changing its
payload is a conflict. The ledger identity is persisted by Rails before POST and
sent as a precondition, preventing replay if the volume is replaced. No automatic
synchronous fallback occurs against an old runtime.

The shim must have **one process** owning this ledger (many request/turn threads
are fine). A filesystem owner lock rejects another shim process. A shim restart
marks unfinished entries unknown and does not replay them. This conservative
choice also covers tools that may already have had external side effects.
Ledger entries are currently retained as deduplication tombstones indefinitely;
size monitoring/retention is an operational follow-up, not silent deletion.

## Completion and cancellation

Activity callbacks still update conversation cards promptly. They do not release
admission capacity. Only the runtime's durable terminal result does that. Polling
recovers missed callbacks and final accounting; delayed callbacks cannot create a
replacement execution. Each new execution uses a new interaction/dispatch UUID.

The runtime updates its ledger heartbeat independently of model output.
Heartbeats and timeouts are diagnostics, **not proof of process exit**. Unknown
turns retain capacity. Cancellation requests set a flag; the supervisor kills its
own process group and waits for root exit before acknowledging cancellation.
Detached processes outside that group, subagents, browsers, builds and external
side effects are not covered by the top-level turn cap.

A turn caused by a human message or a native invoke carries its
`MessageDispatch`. Its claim happened within the dispatch's ten-minute initial
window, but it can then wait queued for capacity. Admission therefore rechecks
the dispatch before the turn is submitted: a discarded source message, an author
who lost membership, live activity switched off, or a dispatch past its six-hour
no-new-starts boundary cancels the queued turn instead of starting it. A turn
already submitted to the runtime is not recalled; queueing or reservation alone
is never execution.

Nothing is recovered automatically (consultation BjAPDe: Daniel's "just click
again", Chris's objection to a retry buffer). If a wake's enqueue is lost, a
reserved run is never claimed, or a chain's hand-on to the next resident is
lost, nothing re-sends it. The per-minute `MessageDispatchSweepJob` only
records what lapsed: a pending dispatch past its ten-minute expiry becomes
`expired`, an unclaimed run past its deadline is cancelled, and a dispatch past
the six-hour boundary is closed (`continuation_not_started_in_time` if a chain
step it owed never started). A native send retry settles status the same way
and never re-drives. The person asks again.

The remaining boundaries, stated narrowly: a first run must be claimed within
ten minutes of acceptance; each later link of an "Ask all" chain is started
only by the previous resident's normal hand-on, with no time limit of its own,
and no new link starts after six hours from acceptance; admission rechecks the
dispatch before a queued turn's first runtime submission. None of these
bounds when a turn actually runs once submitted. A turn whose outcome is
unknown keeps occupying capacity and blocks another turn for the same runtime
session (enqueue refuses it as busy; admission skips that session). That is a
per-session guard, not a guarantee that no other request for the resident
exists elsewhere.

Telegram refuses a second pending request for the same session with the existing
busy response. Its job retries and rebuilds the message window after completion,
instead of storing overlapping stale transcripts and executing them twice.
Orientation/safeguard/provider-result bookkeeping is deferred until completion.

## Controls

Site Admin → **Resident Concurrency** (`/admin/resident_turns`) shows counts,
residents, kinds, queue/admission/check times and cancellation controls. The limit
is editable (0 pauses new admissions). Lowering it never kills running work.
These are admission counts, not host resource or provider-quota measurements;
keep using host/container monitoring and provider usage diagnostics alongside it.

Uncertain executions deliberately have no one-click “free slot” button. After an
operator verifies that the old process group/container has stopped, a site admin
can use the Rails console:

```ruby
turn.resolve_after_containment!(
  operator: administrator,
  reason: "Verified old container stopped; replacement contains no old processes"
)
```

This records the administrator and reason. The runtime must be reachable and
confirm an unknown entry (or a replaced ledger with no entry). A running or
unreachable runtime is rejected. Do not use this as a timeout escape hatch.

## Rollout and rollback

1. Migrate Rails; persist `SOULSHOUSE_ASYNC_TURNS=0`. Deploy compatible runtimes
   only after their current turns finish. Keep the persistent Chaos volume.
2. Pause trigger producers/maintenance during the mode switch, drain legacy
   synchronous work, set the admin limit to **10**, then enable the Rails flag
   and restart Rails/job workers through normal deployment.
3. Canary synthetic conversation and Telegram turns: immediate acceptance,
   model output, result accounting, lost HTTP response, duplicate delivery,
   cancellation, missed callback and shim restart. Verify regular jobs still run.
4. Ramp **10 → 25 → 50**. Measure queue delay, container/host RSS, CPU, PIDs,
   provider throttling and queue/DB connections. 100 is not a verified safe limit.
5. To roll back, pause producers and admission, cancel/drain queued work and
   resolve uncertain executions only after containment. Disable the flag only
   after all asynchronous turns are terminal; otherwise legacy work could bypass
   their capacity reservations. Keep the ledger and database records.

No runtime restart, deployment or live acceptance test is performed by the
repository's synthetic test suite.
