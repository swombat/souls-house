# Hosted-agent runtime observability — forward-only implementation plan

Date: 2026-07-18

Status: implemented on 2026-07-18; deployment verification remains

Implementation note: Phases 0–3 are represented by deterministic Chaos contract
tests, forward-only HelixKit capture/persistence, and the administrator session
timeline. Historical recovery and optional per-provider-request event storage
remain deliberately out of scope. Production verification must use the normal
image/Kamal path and a disposable agent.

Related:

- `docs/requirements/20260718-hosted-agent-runtime-observability.md`
- `agent-runtime/trigger_shim.py`
- `test/lib/trigger_shim_session_test.rb`
- Chaos `sys/exec/fork/src/event_processor_with_jsonl_output.rs`
- Chaos `lib/libcontract/ipc/src/protocol/events_token.rs`
- Chaos `sys/kern/providers/parrot/src/anthropic.rs`

## Purpose

Build trustworthy, forward-looking observability for hosted-agent sessions.

The implementation has three separate responsibilities:

1. **Chaos reports accurate usage and lifecycle facts about one invocation.**
2. **HelixKit records those facts against the interaction and session that caused
   them.**
3. **HelixKit displays session summaries and interaction timelines that explain
   where tokens are going.**

There is a short Chaos-characterisation step before those implementation phases.
Its purpose is to turn assumptions about current Chaos behaviour into executable
tests.

This plan does not attempt to reconstruct historical usage.

## Explicit scope decisions

### Forward-only accounting

Detailed observability begins when the instrumented Chaos runtime and HelixKit
consumer are deployed.

Do not:

- backfill new token categories on old interaction rows;
- query or replay old Chaos session history to manufacture missing usage;
- recover usage that occurred before an already-running session first reports
  the new contract;
- infer cache creation from old blended token totals;
- assign zero to a field that was not reported.

Historical and old-runtime rows may continue to show the existing coarse fields.
New fields should display as `unknown` when they were not reported.

### Prefer invocation-local usage

The primary accounting object is one HelixKit runtime interaction: one request
to the hosted runtime and the complete Chaos invocation it causes.

Chaos should report usage for that invocation directly. HelixKit should not have
to reconstruct it by subtracting process-lifetime counters stored in a sidecar.

An invocation includes:

- the initial provider request;
- provider continuations after tool calls;
- a Stop-hook continuation, if one occurs before the invocation completes;
- any other provider request made as part of the same `chaos exec`.

Chaos may additionally report process/session cumulative totals, but they must
be separately named and must not be confused with invocation-local usage.

### Tokens, not authoritative dollars

Persist token categories and lifecycle facts. Do not make estimated cost the
source of truth in the first implementation.

The UI may later estimate cost from a versioned model-pricing table, but the
observability contract should remain correct when prices or model aliases
change.

### No raw prompt expansion

Record prompt sizes and lifecycle metadata, not additional copies of prompt,
identity, journal, transcript, or tool-output contents.

Existing debug fields can remain under their existing authorization boundary.
The new diagnostics screen should be administrator-only initially.

---

## The three objects that must remain distinct

### HelixKit interaction

One Rails request to the external runtime, stored as
`AgentRuntimeInteraction`.

This is the unit against which invocation-local usage is recorded.

### Logical agent session

The HelixKit `session_id`, such as a conversation, Telegram thread, or wake
session. It may span multiple runtime interactions.

This is the main grouping used by the session summary screen.

### Chaos process

The Chaos `process_id` used for fresh execution and resume. A logical HelixKit
session may use more than one Chaos process because of model changes, identity
changes, failed resumes, deployment, or deliberate rolling.

A single Chaos process may receive many HelixKit interactions.

### Provider request

One request dispatched by Chaos to Anthropic or another model provider.

There may be several provider requests in one Chaos invocation because of tools
or lifecycle hooks. `provider_request_count` therefore cannot be inferred from
HelixKit interaction count.

---

## Canonical forward contract

The final shim response should carry a versioned telemetry object:

```json
{
  "telemetry": {
    "schema_version": 1,
    "runtime": {
      "chaos_version": "chaos 0.1.0 (abcdef1)",
      "provider": "anthropic",
      "model": "claude-fable-5",
      "cache_ttl": "1h"
    },
    "session": {
      "logical_session_id": "<agent-uuid>-519",
      "persistent_requested": true,
      "mapping_found": true,
      "resume_attempted": true,
      "outcome": "resumed",
      "roll_reason": null,
      "changed_identity_files": [],
      "prior_chaos_process_id": "019f...",
      "chaos_process_id": "019f...",
      "trigger_sequence": 5,
      "session_age_seconds": 522
    },
    "prompt": {
      "mode": "delta",
      "full_prompt_bytes": 92338,
      "delta_prompt_bytes": 3145,
      "selected_prompt_bytes": 3145,
      "components": {}
    },
    "usage": {
      "scope": "invocation",
      "input_tokens": 171220,
      "uncached_input_tokens": 1420,
      "cache_creation_input_tokens": 3800,
      "cache_read_input_tokens": 166000,
      "output_tokens": 620,
      "reasoning_output_tokens": null,
      "provider_request_count": 3
    }
  }
}
```

Token arithmetic, when every input category is reported:

```text
input_tokens =
  uncached_input_tokens
  + cache_creation_input_tokens
  + cache_read_input_tokens
```

`NULL` means not reported or not available. Zero means the runtime/provider
reported none.

The existing top-level fields can remain temporarily for compatibility, but the
new recording and diagnostics code should use the versioned telemetry object.

---

## Phase 0 — Characterise the current Chaos harness

### Goal

Establish exactly what Chaos currently reports, at which event boundary, and
whether each value is provider-request-local, turn-local, or process-cumulative.

This phase should produce tests and a short finding, not production telemetry.

### Questions to answer

1. What `TokenCount` events are emitted during one simple model response?
2. Does `turn.completed.usage` currently contain:
   - the latest provider request;
   - the current turn/invocation;
   - or the entire resumed process lifetime?
3. When one turn invokes a tool and calls the provider again, are both provider
   requests included in the final total?
4. Is the Stop-hook continuation included before `turn.completed`?
5. On `chaos exec resume`, does the emitted usage begin at zero for the new
   invocation or include previous turns?
6. Does Anthropic usage preserve these provider categories internally:
   - ordinary input;
   - cache creation;
   - cache read;
   - output?
7. At what layer is `cache_creation_input_tokens` currently collapsed?

### Tests

Add narrowly focused tests rather than a broad integration suite.

#### A. Event-processor fixture test

Location:

- `sys/exec/fork/tests/suite/event_processor_with_json_output.rs`

Feed the JSON event processor a deterministic sequence:

1. `SessionConfigured`
2. `TurnStarted`
3. a first `TokenCount` with known totals
4. a tool begin/end pair
5. a second `TokenCount` with larger known totals
6. `TurnComplete`

Assert the exact `turn.completed` JSON usage emitted at the end.

This establishes what the JSONL boundary does independently of a real provider.

#### B. Token accumulation test

Location:

- `lib/libcontract/ipc/src/protocol/events_token.rs`
- the existing session/token tests around `TokenUsageInfo`

Construct two provider-usage values and assert:

- `last_token_usage` is the second value;
- `total_token_usage` is their element-wise sum;
- cache read and cache creation remain distinct after the Phase 1 change;
- context-window totals are not accidentally used as billed prompt totals.

#### C. Resume harness test

Use a disposable Chaos process and deterministic/fake provider:

1. execute a first turn;
2. capture its process ID and final JSONL;
3. resume the same process for a second turn;
4. capture the second JSONL;
5. assert the documented scope of every usage object.

The test should make the distinction explicit. For example:

```text
first invocation usage:  input=100, output=10
second invocation usage: input=140, output=12
session cumulative:      input=240, output=22
```

Do not leave a test whose correctness depends on knowing that an ambiguously
named `usage` field happens to be cumulative.

#### D. Anthropic adapter test

Feed a recorded/synthetic Anthropic SSE usage sequence containing:

```text
input_tokens
cache_creation_input_tokens
cache_read_input_tokens
output_tokens
```

Assert all four survive the adapter mapping.

No live provider call is required for the deterministic test.

#### E. Optional one-call smoke test

After deterministic tests pass, run one explicitly opt-in test against a
non-production Anthropic account/model:

- one short prompt;
- no tools;
- cache enabled;
- save the raw JSONL as a local test artifact;
- assert categories and scope, not exact token counts.

This is a sanity check, not part of the normal test suite.

### Deliverable

A brief checked-in note or test comment stating:

- current behaviour;
- desired behaviour;
- the exact contract Phase 1 will expose.

### Exit criterion

We can explain, from tests, what each current counter means and why the proposed
invocation-local contract is correct.

---

## Phase 1 — Chaos instrumentation

### Goal

Make Chaos emit an accurate, unambiguous usage summary for one invocation.

### 1. Preserve all provider token categories

Extend canonical `TokenUsage` to preserve:

```text
input_tokens
cache_creation_input_tokens
cached_input_tokens / cache_read_input_tokens
output_tokens
reasoning_output_tokens
```

Keep `cached_input_tokens` as a compatibility alias if needed, but document that
it means cache-read input. New JSON should use `cache_read_input_tokens`.

Update:

- Anthropic adapter mapping;
- `TokenUsage::add_assign`;
- defaults and constructors;
- ABI/IPC serialization;
- TypeScript/schema snapshots;
- display helpers that currently calculate “non-cached” input.

The existing helper:

```text
input_tokens - cached_input_tokens
```

will still blend ordinary input and cache creation. Rename or document that
helper rather than presenting it as ordinary uncached input.

### 2. Count provider requests

Increment `provider_request_count` at the point Chaos dispatches an actual
provider request.

Do not increment it for:

- a HelixKit trigger;
- `chaos exec`;
- a tool call itself;
- an item/event emitted to JSONL;
- a resume operation that makes no provider request.

The final count must include all provider requests completed within the
invocation, including tool continuations and the Stop hook.

### 3. Emit invocation-local usage

At invocation start, capture the process cumulative usage baseline and provider
request baseline. At invocation completion, subtract the baseline and emit the
delta as an explicitly scoped object.

Preferred JSONL shape:

```json
{
  "type": "turn.completed",
  "telemetry_schema_version": 1,
  "usage": {
    "scope": "invocation",
    "input_tokens": 171220,
    "uncached_input_tokens": 1420,
    "cache_creation_input_tokens": 3800,
    "cache_read_input_tokens": 166000,
    "output_tokens": 620,
    "reasoning_output_tokens": null,
    "provider_request_count": 3
  },
  "session_usage": {
    "scope": "process_cumulative",
    "input_tokens": 804276,
    "cache_creation_input_tokens": 12140,
    "cache_read_input_tokens": 778556,
    "output_tokens": 10108,
    "provider_request_count": 15
  }
}
```

`session_usage` is optional. The load-bearing requirement is the
invocation-local `usage`.

This design means a newly deployed HelixKit consumer can record the next
invocation accurately even if the Chaos process began before observability was
deployed. It does not need to reconstruct the earlier usage.

### 4. Define completion boundaries

`turn.completed` must be emitted only after every provider request that belongs
to the invocation has completed.

If the Stop hook runs as part of the same `chaos exec`, its usage belongs in the
invocation aggregate.

If Chaos cannot currently guarantee that ordering, add a distinct
`invocation.completed` event rather than overloading an earlier turn-completion
event.

### 5. Failure semantics

For a failed invocation:

- emit usage accumulated before failure if Chaos has it;
- mark the event/status as incomplete;
- never report a successful complete aggregate when requests may still be
  running;
- do not fabricate missing provider categories.

Timeouts imposed by the outer HelixKit shim may still prevent a final Chaos event
from being received. Forward observability should make those rows visibly
incomplete; historical recovery is out of scope.

### Phase 1 tests

#### Token contract

1. Anthropic mapping preserves ordinary input, cache creation, cache read, and
   output.
2. `TokenUsage::add_assign` sums every category.
3. Serialization emits the new fields.
4. Missing provider categories remain unknown where the contract permits
   unknown values.
5. Arithmetic invariants are checked when all categories are available.

#### Invocation scope

1. One provider request produces `provider_request_count = 1`.
2. A tool-using turn with three provider dispatches produces count 3.
3. A Stop-hook continuation is included in the same invocation aggregate.
4. A second invocation on a resumed process reports only the second invocation
   in `usage`.
5. Optional `session_usage` equals the sum of both invocations.
6. A failed provider request is counted according to a documented rule and its
   available usage is retained.

#### JSONL contract

1. `turn.completed` or `invocation.completed` carries
   `telemetry_schema_version`.
2. `usage.scope` is exactly `invocation`.
3. `session_usage.scope`, if present, is exactly `process_cumulative`.
4. Existing unrelated JSONL event shapes remain unchanged.

### Phase 1 exit criteria

- No subtraction in HelixKit is needed to determine usage for a new
  interaction.
- Cache creation and cache read are separately visible.
- Provider request count is accurate.
- Resume behaviour is covered by a deterministic test.
- The event completion boundary is documented and tested.

---

## Phase 2 — HelixKit capture and persistence

### Goal

Capture the Chaos contract, add shim-owned lifecycle information, and persist one
complete forward-looking interaction record.

### 1. Parse versioned Chaos telemetry in the shim

Update `agent-runtime/trigger_shim.py` to:

- parse `telemetry_schema_version`;
- prefer invocation-local usage;
- preserve unknown fields as `None`;
- include the effective Chaos version/commit;
- reject or clearly mark an unsupported future schema;
- pass through optional process-cumulative usage only for diagnostics.

Do not use `usage_since()` for the new invocation-local contract.

The old cumulative subtraction can remain temporarily for old runtime output,
but it is not part of the new observability design and should not populate the
new detailed fields.

### 2. Add shim-owned session lifecycle telemetry

The shim already knows facts Chaos does not:

- logical HelixKit session ID;
- whether persistence was requested;
- whether a sidecar mapping existed;
- whether resume was attempted;
- whether the invocation ran fresh or resumed;
- why it rolled;
- previous and resulting Chaos process IDs;
- full/delta prompt availability and selected mode;
- prompt byte sizes;
- identity fingerprint comparison;
- trigger sequence and session age.

Record those decisions as they happen rather than reconstructing them from the
final response.

Suggested outcomes:

```text
fresh
resumed
rolled
fresh_fallback
resume_timeout
already_running
failed
```

Suggested roll reasons:

```text
provider-changed
model-changed
identity-changed
resume-failed
sidecar-schema-unsupported
runtime-upgrade
```

### 3. Use content hashes for identity decisions

Replace mtime equality with content fingerprints:

```json
{
  "self-narrative.md": {
    "sha256": "...",
    "bytes": 28114
  }
}
```

An unchanged file touch or deployment rewrite must not roll the session.

A real byte change should record:

```json
{
  "roll_reason": "identity-changed",
  "changed_identity_files": ["self-narrative.md"]
}
```

This is a correctness improvement for future sessions, not historical
reconstruction.

### 4. Record prompt sizes

For every invocation:

```text
full_prompt_bytes
delta_prompt_bytes
selected_prompt_bytes
prompt_mode: full | delta
```

For fresh invocations, optionally record component byte sizes:

```text
identity
request/transcript
journal
other scaffolding
```

Do not store new copies of the component contents.

### 5. Persist additive fields

Add columns to `agent_runtime_interactions` for:

#### Runtime

```text
telemetry_schema_version
chaos_version
provider
model
cache_ttl
```

#### Session lifecycle

```text
persistent_session_requested
session_mapping_found
resume_attempted
session_outcome
session_roll_reason
changed_identity_files
prior_chaos_session_id
chaos_session_id
session_trigger_sequence
session_age_seconds
```

#### Prompt

```text
prompt_mode
full_prompt_bytes
delta_prompt_bytes
selected_prompt_bytes
prompt_component_bytes
```

#### Invocation usage

```text
uncached_input_tokens
cache_creation_input_tokens
cache_read_input_tokens
input_tokens
output_tokens
reasoning_output_tokens
provider_request_count
usage_complete
```

Keep current coarse columns during migration. Do not backfill the new columns.

Use `bigint` for token counters and JSONB only for naturally structured,
low-volume fields such as changed filenames and prompt components.

### 6. Record trigger/channel dimensions

The diagnostics must distinguish at least:

```text
conversation
wake
telegram
memory aggregation
orientation/other
```

Reuse `trigger_kind` where it is already reliable. Add a separate channel only
if `trigger_kind` cannot distinguish conversation and Telegram activity.

### 7. Handle deployment transition honestly

When HelixKit receives:

- an old shim response;
- an old Chaos event;
- an unsupported telemetry version;
- or an incomplete timeout/failure;

it should still record the interaction, but the detailed fields should remain
unknown and the UI should explain why.

Do not attempt to initialise detailed counters by reading an existing Chaos
process's historical total.

### Phase 2 tests

#### Shim parsing

1. Parse all invocation-local categories from a version-1 Chaos event.
2. Keep zero distinct from missing.
3. Ignore process-cumulative usage for interaction billing.
4. Preserve it as optional diagnostics if desired.
5. Parse multiple JSONL events and select the final invocation-completion event.
6. Record fresh and resumed lifecycle decisions.
7. Record model/provider/identity roll reasons.
8. Same-content identity touch does not roll.
9. Real identity bytes change and name the file.
10. Prompt byte sizes and selected mode are exact.
11. Unsupported telemetry versions are recorded as unsupported, not silently
    misparsed.

#### Rails model/persistence

1. Migration types and defaults are correct.
2. `record_result!` persists all runtime, session, prompt, and usage fields.
3. Old response shapes continue to create an interaction without detailed
   telemetry.
4. Unknown remains `NULL`.
5. Zero remains zero.
6. `usage_complete` is false for incomplete/failure output.
7. Raw diagnostics are not added to ordinary chat activity JSON.

#### Boundary contract

Create a fixture JSONL document matching the Chaos test output and use the same
fixture in the shim parser test. This prevents the producer and consumer tests
from independently agreeing with themselves while disagreeing with each other.

### Phase 2 exit criteria

- Every new instrumented interaction records an invocation-local token
  breakdown.
- Every interaction explains fresh/resume/roll/fallback.
- Same-content identity rewrites no longer cause false rolls.
- Old or incomplete output remains recordable without pretending it contains
  detailed telemetry.

---

## Phase 3 — HelixKit session diagnostics UI

### Goal

Provide an administrator screen that makes token usage and session lifecycle
understandable without Rails console work.

### Route and access

Add an admin-only agent runtime diagnostics route, for example:

```text
/accounts/:account_id/agents/:agent_id/runtime
```

Authorisation should match or exceed the existing boundary protecting runtime
stdout, stderr, invocation text, and response bodies.

The default page should not render raw prompts, identity contents, transcripts,
or tool output.

### Screen 1 — Session summary

Group primarily by HelixKit logical `session_id`.

Each row should show:

- session/channel label and linked chat/thread where available;
- trigger kind;
- first and last observed time;
- active duration;
- number of HelixKit interactions;
- number of Chaos processes used;
- fresh/resumed/rolled/fallback counts;
- latest session outcome;
- roll reasons;
- provider and model;
- cache TTL;
- provider request count;
- ordinary input;
- cache creation;
- cache read;
- output;
- total selected prompt bytes;
- telemetry completeness.

Suggested summary cards for the selected UTC window:

```text
Interactions
Logical sessions
Chaos processes
Provider requests
Fresh / resumed / rolled
Ordinary input
Cache writes
Cache reads
Output
Rows with incomplete telemetry
```

Do not combine token categories into a single “input” number without also
showing the category breakdown.

### Screen 2 — Session detail/timeline

Clicking a logical session should show interactions in chronological order:

```text
15:14 fresh   model-changed     process A  full   90 KB
15:20 rolled  identity-changed  process B  full   92 KB
15:22 resumed                   process B  delta   3 KB
15:24 resumed                   process B  delta   4 KB
```

For every interaction show:

- exact UTC start/end;
- duration;
- fresh/resume/roll/fallback badge;
- prior and resulting Chaos process;
- prompt mode and sizes;
- provider/model/cache TTL;
- provider request count;
- uncached input;
- cache creation;
- cache read;
- output;
- whether usage is complete;
- link to the associated chat/runtime interaction where authorised.

This timeline is the primary diagnostic. Automatic alarms should wait until real
baseline data exists.

### Screen 3 — Chaos-process grouping

The session detail should allow grouping or filtering by Chaos process ID.

This answers:

- how many HelixKit interactions reused this process;
- how its per-invocation cache reads changed as the context grew;
- when and why HelixKit moved to another process;
- whether one logical session is unexpectedly churning processes.

### Filters

At minimum:

- UTC time range;
- agent;
- trigger kind/channel;
- provider;
- model;
- session outcome;
- roll reason;
- complete/incomplete telemetry.

Default to a small recent window, such as 24 hours, so the page remains cheap.

### Summary service

Add a query/service object, for example:

```ruby
AgentRuntimeUsageReport.new(
  agent: agent,
  from: ...,
  to: ...
).call
```

Its return value should power both the UI and console diagnostics.

The report must state its exact UTC window and aggregate only invocation-local
usage.

### Phase 3 tests

#### Query/report tests

1. Group interactions by logical session.
2. Keep different Chaos processes within one logical session visible.
3. Sum invocation-local usage exactly once.
4. Do not include process-cumulative diagnostic totals in token sums.
5. Group by trigger kind, provider, model, outcome, and roll reason.
6. Report unknown/incomplete rows separately.
7. Apply exact UTC boundaries.

#### Controller/view tests

1. Administrators can access the diagnostics.
2. Ordinary account users cannot access it unless explicitly authorised.
3. Session summary displays lifecycle and all token categories.
4. Session detail displays chronological interactions.
5. Missing telemetry displays as unknown, not zero.
6. Raw invocation, identity, transcript, and tool-output contents are not shown
   on the summary page.
7. Filters preserve UTC range and grouping.

#### Performance test

Create a realistic number of interactions and assert the summary avoids one
query per session/interaction. Add indexes only after checking the actual query
plan.

Likely useful indexes:

```text
(agent_id, started_at)
(agent_id, session_id, started_at)
(agent_id, chaos_session_id, started_at)
(agent_id, session_outcome, started_at)
```

### Phase 3 exit criteria

- An administrator can identify expensive logical sessions without a console.
- The screen distinguishes HelixKit sessions, Chaos processes, and provider
  requests.
- Token totals are traceable to individual interactions.
- Session churn and long-context cache-read growth are visible.
- Missing telemetry is visible rather than silently excluded.

---

## Phase 4 — End-to-end verification and deployment

### Consumer-before-producer deployment

1. Deploy HelixKit migrations and tolerant recording code.
2. Deploy shim lifecycle telemetry.
3. Merge and pin the instrumented Chaos commit in the runtime image.
4. Build and deploy the hosted runtime through the normal Kamal workflow.
5. Use a disposable agent for verification.
6. Enable the diagnostics screen.
7. Observe at least one full day before choosing cost optimisations.

Do not mutate production containers manually.

### Disposable-agent test

1. Start a new logical conversation session.
   - fresh;
   - full prompt;
   - one Chaos process;
   - invocation-local usage present.
2. Send a second message.
   - resumed;
   - same Chaos process;
   - delta prompt;
   - cache read visible.
3. Cause a tool-using response.
   - provider request count greater than one;
   - invocation total includes all calls.
4. Exercise the Stop hook.
   - invocation total includes it;
   - if attribution is not yet available, no phase is fabricated.
5. Touch an identity file without changing bytes.
   - no roll.
6. Change `self-narrative.md` bytes.
   - one identity roll;
   - changed filename visible.
7. Change model.
   - one model roll;
   - new Chaos process.
8. Open the diagnostics UI.
   - one logical session;
   - multiple interactions;
   - process transition visible;
   - token totals equal the sum of interaction rows.
9. Compare one exact UTC window with the provider dashboard.
   - use only traffic generated after the new contract was deployed;
   - do not attempt to reconcile earlier usage.

### What to decide after observation

Only after the instrumentation is trusted should we decide whether to:

- gate or fold the Stop reflex;
- shorten cache TTL for bursty conversation/Telegram sessions;
- retain a longer TTL for scheduled wakes;
- compact or deliberately roll long sessions;
- alter the stable prompt/cache-breakpoint architecture;
- reduce false session churn further.

---

## Important risks and safeguards

### Ambiguous usage scope

This is the largest technical risk. A field named only `usage` is insufficient
unless its scope is part of the contract and tested across resume.

### Double counting

Never add both invocation usage and process-cumulative usage into the same
report.

### Incomplete invocations

Timeout and failure rows must be visible as incomplete. Their known usage may be
recorded, but completeness must not be implied.

### Provider variation

Some providers may not expose cache categories or reasoning output. Preserve
unknown values rather than forcing the Anthropic shape onto every provider.

### Privacy

Prompt sizes, hashes, process IDs, and token counts are useful without exposing
prompt contents. Keep diagnostics admin-only until the exposure boundary has
been reviewed.

### UI conclusions before baseline

Build the timeline before alarms. Do not encode guessed thresholds before real
traffic establishes normal behaviour by trigger kind and model.

---

## Recommended implementation slices

### Chaos slice A — Characterisation tests

Deliverable:

- executable proof of current simple/tool/resume usage semantics.

### Chaos slice B — Usage fidelity

Deliverable:

- separate cache creation/read categories;
- provider request count;
- invocation-local, versioned completion usage.

### HelixKit slice A — Capture

Deliverable:

- shim lifecycle and prompt telemetry;
- versioned Chaos parser;
- additive interaction persistence;
- content-hash identity fingerprints.

### HelixKit slice B — Reporting

Deliverable:

- UTC summary service;
- logical-session summary screen;
- interaction and Chaos-process timeline.

### Integration slice

Deliverable:

- disposable-agent run whose UI totals reconcile with the emitted Chaos
  invocation events and the provider dashboard for a post-deployment UTC
  window.

---

## Definition of done

1. Chaos tests prove what one invocation includes.
2. Cache creation and cache read remain separate from the Anthropic adapter to
   HelixKit storage.
3. One invocation reports its own usage without HelixKit subtracting historical
   process totals.
4. Provider request count is accurate for simple, tool-using, and Stop-hook
   invocations.
5. Every new instrumented interaction explains fresh/resume/roll/fallback.
6. Same-content identity rewrites do not roll sessions.
7. HelixKit groups interactions by logical session while preserving Chaos
   process transitions.
8. The diagnostics screen shows token categories per session and per
   interaction.
9. Unknown and incomplete data are visibly distinct from zero.
10. A post-deployment UTC window can be reconciled without recovering any
    historical usage.
