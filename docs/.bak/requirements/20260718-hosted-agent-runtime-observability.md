# Hosted-agent runtime observability — session lifecycle and token accounting

Date: 2026-07-18

Status: implemented on 2026-07-18; deployment verification remains

Related documents:

- `docs/hosted-agent-token-economics-2026-07-14.md`
- `docs/per-chat-session-resume-2026-07-15.md`
- `agent-runtime/trigger_shim.py`
- Chaos prompt-caching change `e2a6221f4` / merge `cbd489164`

## Executive summary

The immediate problem is no longer simply "prompt caching is absent." Anthropic
prompt caching is enabled in Chaos, and stable resumed HelixKit sessions show
very high cache-read ratios. The remaining bill is difficult to explain because
the current telemetry loses two important distinctions:

1. Chaos receives ordinary input, cache-creation input, and cache-read input as
   separate provider counters, but collapses cache creation into the generic
   `input_tokens` total before emitting `turn.completed`.
2. HelixKit records whether the final result says a session was resumed, but not
   the complete decision path: whether a mapping existed, whether resume was
   attempted, which files changed, why a session rolled, how large the selected
   prompt was, or how many provider requests the Chaos turn made.

This means the first observability improvement spans both repositories:

- **HelixKit and `trigger_shim.py` can instrument the session lifecycle without
  changing Chaos.** The shim already makes the fresh/resume/roll/fallback
  decisions and knows the prompt sizes and sidecar state.
- **Exact cache-creation accounting requires a small Chaos contract change.**
  The Anthropic adapter already has the number; Chaos currently discards its
  separate identity before the JSONL event reaches the shim.
- **Per-provider-request attribution may require a second, optional Chaos
  change.** Start with aggregate counts. Add call-level events only if aggregate
  cache creation plus lifecycle telemetry still cannot explain the bill.

The proposed order is deliberately diagnostic:

1. Persist the lifecycle facts the shim already knows.
2. Preserve cache-creation tokens through Chaos's event contract.
3. Add provider request counts and, only if needed, per-request usage events.
4. Observe real traffic for at least a full day.
5. Use those measurements to choose the actual cost fixes: reducing false
   session rolls, changing cache TTLs, gating the Stop reflex, or compacting
   long sessions.

Do not optimize the journal loader or heartbeat cadence first. Current evidence
does not support journal-file appends invalidating a successfully resumed
session.

---

## Why this work is needed

### What the July 17 investigation established

The Fable interactions around conversation `oewxyj` showed:

| Scope | Input tokens | Cache-read tokens | Cache-read ratio | Output tokens |
|---|---:|---:|---:|---:|
| First confirmed Fable interactions, 377–382 | 2,452,514 | 2,303,201 | 93.9% | 25,991 |
| Stable resumed interactions, 379–382 | 1,845,785 | 1,797,168 | 97.4% | 17,452 |

That is evidence that caching is functioning during stable resume. It is not
evidence that the resulting economics are good: repeatedly reading a large
cached context, producing expensive output, and writing every newly appended
suffix can still cost a great deal.

The same sequence contained three fresh starts:

- Interaction 376: `identity-changed`
- Interaction 377: `model-changed`
- Interaction 378: `identity-changed`
- Interaction 379 onward: stable resume

Fresh interactions 376–378 each injected roughly 90–92 KB of initial prompt.
The first resumed interaction sent only a roughly 3 KB delta.

### Why the daily-journal cache-busting hypothesis does not fit the code

On successful resume, `trigger_shim.py` sends:

```text
chaos exec --json ... resume <process_id> -
```

with `request_delta`, not `build_prompt(request)`. It does not:

- re-read identity files;
- re-read daily journals;
- rebuild the initial HelixKit transcript;
- put the changed journal file back into the model prefix.

The Stop hook still costs money because it creates another continuation, often
including a tool call that appends the journal. That adds cache reads, output,
and a new suffix to cache. The file append itself does not rewrite the prior
session prefix.

On fresh sessions, the journal loader is already bounded:

- most recent journal threshold: 12,000 characters;
- most recent journal tail: 10,000 characters;
- total journal context: 16,000 characters.

The measured journal section in fresh interaction 378 was approximately 10.1
KB, not the full 82 KB file on disk. Journal memory is also already placed after
the live request/transcript in `build_prompt`.

### The current accounting blind spot

The Anthropic adapter currently parses:

```rust
input_tokens
cache_creation_input_tokens
cache_read_input_tokens
output_tokens
```

but converts them to Chaos `TokenUsage` as:

```rust
input_tokens =
  input_tokens +
  cache_creation_input_tokens +
  cache_read_input_tokens

cached_input_tokens = cache_read_input_tokens
```

By the time `chaos exec --json` emits `turn.completed`, cache creation is no
longer separately identifiable. The shim and HelixKit therefore receive:

```json
{
  "input_tokens": 804276,
  "cached_input_tokens": 778556,
  "output_tokens": 10108
}
```

but cannot tell how the remaining 25,720 input tokens divide between:

- ordinary uncached input;
- cache-creation input.

This is exactly the distinction needed to reconcile HelixKit interactions with
the provider dashboard's input/cache-read/cache-write categories.

---

## Questions the instrumentation must answer

After this work, one interaction row should be enough to answer:

1. Did HelixKit request persistence for this trigger?
2. Which HelixKit logical session key was used?
3. Did the shim find a sidecar mapping?
4. Did it attempt resume?
5. Did it run fresh, resume successfully, roll deliberately, or fall back after
   a failed resume?
6. If it rolled, exactly why?
7. If identity changed, which fingerprinted files changed?
8. Were the bytes actually different, or was only an mtime changed?
9. What were the previous and resulting Chaos process IDs?
10. Was the invocation sent as a full prompt or a delta?
11. How large were the available full prompt, available delta, and selected
    invocation?
12. Which provider, model, and cache TTL were used?
13. How old was the resumed session and how many HelixKit triggers had already
    used it?
14. How many provider requests occurred inside the Chaos turn?
15. Across those requests, how many tokens were:
    - ordinary uncached input;
    - cache creation;
    - cache read;
    - output;
    - reasoning output, if the provider exposes it?
16. Did a Stop-hook continuation occur, and how much of the turn did it account
    for?
17. Can the aggregate be reconciled with the Anthropic usage dashboard for the
    same time window?

Questions 1–13 are primarily shim/HelixKit work. Questions 14–16 require Chaos
to expose information that currently remains inside the process.

---

## Desired telemetry model

### Keep three levels distinct

The system currently blurs three different objects:

1. **HelixKit interaction**
   - One Rails request to the external runtime.
   - Stored as `AgentRuntimeInteraction`.
2. **Chaos process/session**
   - Identified by `chaos_session_id` / Chaos `process_id`.
   - Can span many HelixKit interactions through `exec resume`.
3. **Provider request**
   - One Anthropic Messages API call.
   - A single Chaos turn may make several because of tools and the Stop-hook
     continuation.

The data model and names should preserve these levels. In particular,
`provider_request_count` is not the same as HelixKit interaction count, and
`session_resumed` is not the same as "the provider cache was read."

### Canonical token semantics

Use these names end to end:

```text
input_tokens
  Total provider prompt tokens:
  uncached_input_tokens + cache_creation_input_tokens + cache_read_input_tokens

uncached_input_tokens
  Ordinary input that was neither read from nor written to a prompt cache.

cache_creation_input_tokens
  Input tokens written into the provider prompt cache.

cache_read_input_tokens
  Input tokens served from the provider prompt cache.

output_tokens
  Provider output tokens.

reasoning_output_tokens
  Provider-reported reasoning/thinking output when separately available.
```

Keep `cached_input_tokens` as a temporary compatibility alias for
`cache_read_input_tokens`; do not use the ambiguous name in new code or UI.

For providers that do not expose a category, store `NULL`, not a fabricated
zero. Zero means "the provider reported none"; `NULL` means "unknown or not
available."

### Do not make cost estimates the source of truth

Persist tokens and lifecycle facts. Provider prices change, model aliases can
move, and account-specific pricing may differ. A later reporting layer can
estimate cost from a versioned price table, but the first implementation should
not bake current Fable or Opus prices into interaction rows.

---

## Phase 1 — Shim-owned session lifecycle telemetry

This phase can land in HelixKit without waiting for Chaos.

### 1.1 Extend the shim response

`agent-runtime/trigger_shim.py` should return a structured `session` object:

```json
{
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
    "sidecar_created_at": "2026-07-17T15:20:19Z",
    "sidecar_last_finished_at": "2026-07-17T15:27:42Z",
    "session_age_seconds": 522,
    "trigger_sequence": 5,
    "fresh_fallback": false
  },
  "prompt": {
    "mode": "delta",
    "full_prompt_bytes": 92338,
    "delta_prompt_bytes": 3145,
    "selected_prompt_bytes": 3145
  },
  "runtime": {
    "provider": "anthropic",
    "model": "claude-fable-5",
    "cache_ttl": "1h",
    "timeout_seconds": 1800
  }
}
```

Suggested `session.outcome` values:

- `legacy_fresh`
- `fresh`
- `resumed`
- `rolled`
- `fresh_fallback`
- `resume_timeout`
- `already_running`
- `failed`

Keep the existing top-level fields (`session_resumed`, `fresh_fallback`,
`chaos_session_id`) during migration for backwards compatibility.

### 1.2 Record the complete decision, not only the final state

The shim should build a lifecycle record at the start of `persistent_trigger`
and update it as decisions happen. This avoids reconstructing intent after the
fact.

Examples:

- A model change should record:
  - mapping found: true;
  - resume attempted: false;
  - outcome: rolled;
  - roll reason: model-changed;
  - previous and new process IDs.
- A stale mapping should record:
  - mapping found: true;
  - resume attempted: true;
  - returned process ID did not match;
  - outcome: fresh-fallback;
  - roll reason: resume-failed.
- A timeout should record:
  - resume attempted: true;
  - outcome: resume-timeout;
  - mapping retired: true.

### 1.3 Replace mtime-only fingerprints with content fingerprints

The current identity fingerprint stores `st_mtime_ns` for:

- `soul.md`
- `runtime-instructions.md`
- `self-narrative.md`
- `bootstrap.md`

This can roll every session when deployment or synchronization rewrites an
unchanged file. Replace each value with:

```json
{
  "sha256": "...",
  "bytes": 28114
}
```

Do not include mtimes in the equality check. An mtime may remain as diagnostic
metadata, but bytes determine whether identity changed.

When comparing a sidecar record with current identity, return both:

```python
roll_reason = "identity-changed"
changed_identity_files = ["self-narrative.md"]
```

This has two benefits:

- prevents false cold starts caused by same-content rewrites;
- distinguishes a genuine self-narrative update from a runtime instruction or
  bootstrap change.

Content hashes are safe to persist; raw identity contents are not needed in the
lifecycle telemetry.

### 1.4 Add sidecar schema version and sequence

Add to each session sidecar:

```json
{
  "schema_version": 2,
  "trigger_sequence": 5
}
```

The shim should read version-1 records defensively and upgrade them on the next
successful write. Unknown future versions should retire safely and start fresh
with a clear `sidecar-schema-unsupported` roll reason.

### 1.5 Prompt-size telemetry

Record byte counts, not prompt contents:

- `full_prompt_bytes`
- `delta_prompt_bytes`
- `selected_prompt_bytes`
- optional component sizes on fresh prompts:
  - `identity_prompt_bytes`
  - `request_prompt_bytes`
  - `journal_prompt_bytes`

Component sizes make claims such as "the journal loaded 82 KB" directly
verifiable without storing another copy of private prompt text.

### 1.6 Cache TTL telemetry

The shim should report the effective TTL passed to Chaos:

```text
off | 5m | 1h | unknown
```

Today the adapter can take it from a request extension or
`CHAOS_ANTHROPIC_CACHE_TTL`. The selected value must be visible per interaction
before experimenting with trigger-specific TTLs.

---

## Phase 2 — HelixKit persistence and diagnostics

### 2.1 Schema changes

Add additive columns to `agent_runtime_interactions`:

```ruby
add_column :agent_runtime_interactions, :provider, :string
add_column :agent_runtime_interactions, :model, :string
add_column :agent_runtime_interactions, :cache_ttl, :string

add_column :agent_runtime_interactions, :persistent_session_requested, :boolean
add_column :agent_runtime_interactions, :session_mapping_found, :boolean
add_column :agent_runtime_interactions, :resume_attempted, :boolean
add_column :agent_runtime_interactions, :session_outcome, :string
add_column :agent_runtime_interactions, :session_roll_reason, :string
add_column :agent_runtime_interactions, :changed_identity_files, :jsonb, default: []
add_column :agent_runtime_interactions, :prior_chaos_session_id, :string
add_column :agent_runtime_interactions, :session_trigger_sequence, :integer
add_column :agent_runtime_interactions, :session_age_seconds, :integer

add_column :agent_runtime_interactions, :prompt_mode, :string
add_column :agent_runtime_interactions, :full_prompt_bytes, :integer
add_column :agent_runtime_interactions, :delta_prompt_bytes, :integer
add_column :agent_runtime_interactions, :selected_prompt_bytes, :integer
add_column :agent_runtime_interactions, :prompt_component_bytes, :jsonb, default: {}

add_column :agent_runtime_interactions, :uncached_input_tokens, :bigint
add_column :agent_runtime_interactions, :cache_creation_input_tokens, :bigint
add_column :agent_runtime_interactions, :cache_read_input_tokens, :bigint
add_column :agent_runtime_interactions, :reasoning_output_tokens, :bigint
add_column :agent_runtime_interactions, :provider_request_count, :integer
```

Existing `input_tokens`, `cached_input_tokens`, and `output_tokens` remain.
`cached_input_tokens` should be populated alongside
`cache_read_input_tokens` during compatibility.

Indexes worth adding:

```ruby
add_index :agent_runtime_interactions, [:agent_id, :started_at]
add_index :agent_runtime_interactions, [:agent_id, :chaos_session_id]
add_index :agent_runtime_interactions, [:agent_id, :session_outcome]
add_index :agent_runtime_interactions, [:agent_id, :session_roll_reason]
```

The first may already be covered; check the schema before adding duplicates.

### 2.2 Store structured telemetry in `record_result!`

`AgentRuntimeInteraction#record_result!` should:

1. Extract `session`, `prompt`, `runtime`, and `usage`.
2. Persist their scalar fields.
3. Keep the full response body for short-term debugging as today.
4. Tolerate old runtime images that do not send the new objects.
5. Derive `uncached_input_tokens` only when all necessary provider categories
   are known:

```ruby
input - cache_creation - cache_read
```

Never derive it from `input - cache_read` after cache-creation support lands;
that repeats the current ambiguity.

### 2.3 Add model-level helpers

Useful methods:

```ruby
interaction.cache_read_ratio
interaction.cache_creation_ratio
interaction.fresh_session?
interaction.resumed_session?
interaction.cold_start?
interaction.provider_requests_per_trigger
interaction.token_breakdown
```

Ratios should return `nil` when the denominator or category is unknown.

### 2.4 Admin-only diagnostics

Do not add raw runtime diagnostics to public chat activity JSON.

Add an administrator-only runtime diagnostics view or endpoint containing:

- lifecycle badge: fresh / resumed / rolled / fallback;
- logical session key and Chaos process ID;
- roll reason and changed filenames;
- prompt mode and byte sizes;
- provider/model/cache TTL;
- token category table;
- provider request count;
- duration;
- links to adjacent interactions in the same logical and Chaos sessions.

The existing `full_invocation_text`, stdout, stderr, and response body can
contain identity, transcript, commands, and tool output. They must remain behind
the existing admin/debug authorization boundary. The new metrics are safer, but
should initially live behind the same boundary while their exposure is reviewed.

### 2.5 A session timeline view

The most useful diagnostic is not an isolated row but a session timeline:

```text
15:14 conversation  fresh   model-changed     process A  full 90 KB
15:20 conversation  fresh   identity-changed  process B  full 92 KB
15:22 conversation  resumed                   process B  delta 3 KB
15:24 conversation  resumed                   process B  delta 4 KB
15:27 conversation  resumed                   process B  delta 2 KB
15:29 conversation  resumed                   process B  delta 3 KB
```

For each row, show:

```text
ordinary input / cache write / cache read / output / provider calls
```

This makes cold-start fan-out and long-session growth visible immediately.

---

## Phase 3 — Preserve cache creation through Chaos

This is the minimum Chaos change.

### 3.1 Extend canonical `TokenUsage`

Chaos's canonical token contract currently has:

```rust
pub struct TokenUsage {
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_output_tokens: i64,
    pub total_tokens: i64,
}
```

Add:

```rust
pub cache_creation_input_tokens: i64,
```

Prefer also renaming or documenting:

```rust
cached_input_tokens == cache_read_input_tokens
```

Do not make a breaking rename immediately. Add a helper:

```rust
pub fn cache_read_input(&self) -> i64
```

and preserve the serialized `cached_input_tokens` field until downstream users
have migrated.

Likely affected Chaos files include:

- `lib/libcontract/ipc/src/protocol/events_token.rs`
- ABI/provider token usage types, if separately defined
- session token accumulation and display helpers
- serialization/TypeScript snapshots
- tests constructing `TokenUsage` literals

`add_assign`, defaulting, and any blended-total calculations must include or
deliberately exclude the new field according to their documented semantics.
`input_tokens` should remain the complete prompt total; cache creation is a
subset, just as cache read is.

### 3.2 Preserve the Anthropic counter

`UsageAccumulator` in:

```text
sys/kern/providers/parrot/src/anthropic.rs
```

already stores `cache_creation_input_tokens`. Its `token_usage()` method should
set the new field rather than discard the distinction:

```rust
TokenUsage {
    input_tokens: prompt_tokens as i64,
    cache_creation_input_tokens: self.cache_creation_input_tokens as i64,
    cached_input_tokens: self.cache_read_input_tokens as i64,
    output_tokens: self.output_tokens as i64,
    ...
}
```

Other providers should leave the field at zero or unknown according to what
their adapters actually report. The outer HelixKit contract may use `NULL` for
unsupported providers even if Chaos's internal struct defaults to zero.

### 3.3 Extend `chaos exec --json`

`sys/exec/fork/src/exec_events.rs` currently emits:

```rust
pub struct Usage {
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
}
```

Add:

```rust
pub cache_creation_input_tokens: i64,
pub reasoning_output_tokens: i64,
pub provider_request_count: i64,
```

The JSONL should become:

```json
{
  "type": "turn.completed",
  "usage": {
    "input_tokens": 804276,
    "cache_creation_input_tokens": 12140,
    "cached_input_tokens": 778556,
    "output_tokens": 10108,
    "reasoning_output_tokens": 0,
    "provider_request_count": 5
  }
}
```

All fields should be additive and default safely so older consumers continue to
work.

### 3.4 Count provider requests

Increment a counter whenever Chaos dispatches a model provider request, not
whenever a HelixKit trigger, Chaos turn, tool, or output item occurs.

This count closes a major explanatory gap:

- 800 K input over one HelixKit interaction may be one enormous request or five
  repeated reads of a 160 K context.
- The cost remedies are different in those cases.

The counter should aggregate across the primary turn and Stop-hook
continuations included in the `chaos exec` lifecycle.

### 3.5 Compatibility and versioning

The shim must accept both old and new `turn.completed` shapes:

```python
cache_creation_input_tokens = usage.get("cache_creation_input_tokens")
provider_request_count = usage.get("provider_request_count")
```

Missing fields remain `None`; do not silently claim zero cache writes for old
Chaos versions.

The shim health response should expose the Chaos version/commit sufficiently to
tell whether the runtime supports detailed usage.

---

## Phase 4 — Optional per-provider-request usage events

Do not make this a prerequisite for the first deployment.

Aggregate per-trigger counts may be enough to explain the bill. If not, add an
additive JSONL event:

```json
{
  "type": "model.usage",
  "request_sequence": 4,
  "phase": "stop_hook",
  "usage": {
    "input_tokens": 171220,
    "uncached_input_tokens": 1420,
    "cache_creation_input_tokens": 3800,
    "cache_read_input_tokens": 166000,
    "output_tokens": 620
  }
}
```

Suggested `phase` values:

- `primary`
- `tool_continuation`
- `stop_hook`
- `compaction`
- `unknown`

Only emit a phase if Chaos can determine it reliably. Incorrect attribution is
worse than `unknown`.

The shim can aggregate these into:

```json
"provider_requests": [
  {
    "sequence": 1,
    "phase": "primary",
    "usage": { ... }
  }
]
```

HelixKit can initially store the array in a `jsonb` column rather than creating
a second table. If the arrays become large or need querying at scale, normalize
them into `agent_runtime_provider_requests` later.

### Why this phase is optional

The first three phases already reveal:

- cold starts;
- false identity invalidations;
- prompt size;
- aggregate cache creation;
- cache-read ratio;
- model-call count.

Per-request detail is justified only if we still cannot tell whether the Stop
hook, tools, compaction, or ordinary response generation dominates.

---

## Phase 5 — Verification and operational reporting

### 5.1 Reconciliation report

Add a Rails service or console-friendly query that summarizes a time range:

```ruby
AgentRuntimeUsageReport.new(
  agent: agent,
  from: 1.day.ago,
  to: Time.current
).call
```

Expected output:

```text
HelixKit interactions: 48
Fresh sessions: 4
Resumed sessions: 42
Rolls:
  identity-changed: 2
  model-changed: 1
  resume-failed: 1

Provider requests: 137
Input:
  ordinary: 182,000
  cache creation: 301,000
  cache read: 9,430,000
Output: 54,000

Prompt bytes:
  fresh full total: ...
  resumed delta total: ...
```

The report should group by:

- trigger kind: wake / conversation / Telegram / aggregation;
- session outcome;
- model;
- Chaos process ID;
- hour.

This will make it possible to compare the same UTC window with the provider
dashboard without manually summing rows.

### 5.2 Derived alarms

After baseline data exists, add warnings rather than hard policy:

- more than one fresh start for the same logical session in an hour;
- identity-changed roll with no changed content hash;
- cache-read ratio below an expected threshold on a resumed session;
- unusually high cache creation on a resumed interaction;
- provider request count much higher than normal for the trigger kind;
- selected delta prompt unexpectedly close to full-prompt size;
- repeated `fresh_fallback` or `resume-timeout`.

Thresholds must be based on observed traffic, not guessed in the first patch.

---

## Test plan

### Chaos unit tests

1. Anthropic SSE usage preserves all four categories:
   - ordinary input;
   - cache creation;
   - cache read;
   - output.
2. `TokenUsage#add_assign` sums cache creation correctly.
3. JSON serialization includes the new field.
4. `turn.completed` emits cache creation, reasoning output, and provider request
   count.
5. Older/default provider usage produces safe defaults.
6. A multi-call tool turn increments provider request count once per actual
   provider dispatch.
7. If phase attribution is added, Stop-hook and ordinary calls are labelled
   correctly.

### Shim tests

Extend `test/lib/trigger_shim_session_test.rb`:

1. `parse_events` extracts cache creation and provider request count.
2. Cumulative-to-per-trigger subtraction handles the new counters.
3. Counter reset logic handles each new counter independently.
4. First persistent trigger records `fresh`.
5. Second trigger records `resumed`, mapping found, resume attempted, same
   process ID, and delta prompt mode.
6. Model change records `rolled` / `model-changed` without a resume attempt.
7. Provider change records `provider-changed`.
8. Same-content file touch does not roll after content hashing.
9. Actual identity byte change rolls and names the changed file.
10. Stale process ID records both the failed resume attempt and fresh fallback.
11. Timeout records mapping retirement and `resume-timeout`.
12. Sidecar schema-v1 records upgrade safely.
13. Full/delta/selected prompt byte counts are accurate.
14. Missing new Chaos fields remain unknown rather than becoming false zeros.

### Rails tests

1. Migration defaults are correct.
2. `record_result!` persists the structured lifecycle objects.
3. Old shim responses remain valid.
4. Token helpers distinguish unknown from zero.
5. Usage reports group correctly by trigger kind, session outcome, and model.
6. Admin diagnostics show the new metrics.
7. Non-admin routes and chat activity JSON do not expose raw invocation,
   response body, identity hashes, or process diagnostics.

### End-to-end disposable-agent test

Use a disposable hosted agent rather than experimenting against Claude's live
identity:

1. Deploy the instrumented runtime through the normal Kamal/image path.
2. Trigger a new conversation:
   - assert fresh session;
   - assert full prompt mode;
   - assert cache creation is reported.
3. Trigger it again within the cache TTL:
   - assert same Chaos process ID;
   - assert resumed;
   - assert delta mode;
   - assert cache reads are non-zero.
4. Touch a fingerprinted identity file without changing bytes:
   - assert no roll.
5. Change `self-narrative.md` bytes:
   - assert `identity-changed`;
   - assert changed filename is recorded;
   - assert one fresh start.
6. Change model:
   - assert `model-changed`;
   - assert new Chaos process ID.
7. Exercise a tool-using response and a Stop reflex:
   - assert provider request count increases;
   - if Phase 4 exists, inspect per-request phases.
8. Compare the interaction totals with the provider dashboard over the same
   exact UTC interval.

Do not mutate or inspect production containers manually. Build and deploy the
instrumented image through the existing Kamal workflow so the test exercises
the same lifecycle production will use.

---

## Deployment order

The changes are additive, so deploy consumers before producers:

1. **HelixKit migration and tolerant parser**
   - New columns exist.
   - Old runtime responses still work.
2. **Shim lifecycle telemetry**
   - Session facts and prompt sizes become visible immediately.
   - No Chaos dependency.
3. **Chaos token contract**
   - Add cache creation and provider request count.
   - Merge and pin the new Chaos commit in `agent-runtime/Dockerfile`.
4. **Build and deploy the runtime image via Kamal**
   - No manual mutation of running containers.
5. **Disposable-agent verification**
6. **Observe at least one full day**
7. **Choose optimization work from the measured report**

Self-hosted/externally deployed agents running an older runtime image will
continue reporting the old shape. The diagnostics UI should display a clear
"runtime does not report detailed cache usage" state until those agents are
rebuilt through their normal deployment process.

---

## Decisions this instrumentation should enable

### A. Are identity changes causing avoidable cold-start fan-out?

Evidence:

- frequent `identity-changed` rolls;
- same changed filename across wake/chat/Telegram sessions;
- content hash unchanged or file rewritten by deployment.

Likely fix:

- content hashes eliminate false rolls;
- consider delivering genuine self-narrative changes as an appended identity
  update rather than rolling every active session, but only after measuring the
  fan-out and reviewing the semantic trade-off.

### B. Is the Stop reflex the main marginal cost?

Evidence:

- provider request count increases materially on otherwise simple triggers;
- Phase-4 events attribute significant read/write/output to `stop_hook`.

Possible fixes:

- fold the invitation into the primary turn;
- skip it for locally identifiable no-op heartbeats;
- fire only after substantive actions;
- cap journal-entry length.

The target is the extra model continuation, not the journal file append.

### C. Are long sessions dominated by cache-read volume?

Evidence:

- stable resume;
- low cache creation;
- high cache reads;
- provider request count multiplied by a large session context;
- cost rises with session age despite small deltas.

Possible fix:

- compact or roll sessions at a measured context threshold, carrying forward a
  concise summary plus transcript cursor.

### D. Is one-hour cache TTL overpaying for bursty conversations?

Evidence:

- most conversation provider requests and HelixKit replies occur within five
  minutes;
- substantial cache creation under a one-hour TTL;
- little reuse between five minutes and one hour.

Possible fix:

- keep one-hour TTL for half-hourly wakes;
- use a shorter TTL for conversation/Telegram bursts;
- or select TTL adaptively from recent session cadence.

Do not change TTL until it is recorded per interaction and cache-creation
tokens are visible.

### E. Are unavoidable fresh sessions failing to share stable identity cache?

Evidence:

- each new logical session pays a large cache creation for the same identity
  bytes;
- fresh prompt component metrics show identity dominates;
- resumed economics are healthy but first-turn economics remain poor.

Possible fix:

- represent stable identity as a separately cacheable block or breakpoint in
  Chaos rather than concatenating identity, volatile request, and journal into
  one initial user message.

This is a deeper prompt-architecture change and should follow, not precede,
basic instrumentation.

---

## Out of scope for the instrumentation patch

- Changing heartbeat frequency.
- Removing or weakening journals.
- Changing the model.
- Automatically compacting sessions.
- Trigger-specific cache TTL policy.
- Cost-based routing or cheap-model gates.
- A shared global Chaos session across unrelated chats.
- Provider price tables and authoritative dollar accounting.
- Exposing raw prompts or identity contents to ordinary account users.

Those may become sensible follow-ups. The purpose of this patch is to make the
choice evidence-based.

---

## Recommended implementation slices

### Slice 1 — HelixKit/shim lifecycle facts

Files:

- `agent-runtime/trigger_shim.py`
- `test/lib/trigger_shim_session_test.rb`
- migration for `agent_runtime_interactions`
- `app/models/agent_runtime_interaction.rb`
- admin runtime diagnostics/reporting

Deliverable:

- Every interaction explains fresh/resume/roll/fallback and prompt size.

### Slice 2 — Chaos aggregate usage fidelity

Files:

- Anthropic adapter usage mapping
- canonical `TokenUsage`
- Chaos exec `Usage` JSONL contract
- token accumulation/event processor tests

Deliverable:

- `turn.completed` preserves cache creation and provider request count.

### Slice 3 — Reporting and one-day observation

Files:

- `AgentRuntimeUsageReport`
- admin session timeline
- tests and operational documentation

Deliverable:

- A UTC-window report reconcilable with the provider dashboard.

### Slice 4 — Optional provider-call detail

Only start if Slice 3 leaves a material unexplained remainder.

Deliverable:

- Per-provider-request usage and reliable primary/tool/Stop attribution.

---

## Success criteria

The instrumentation is complete when:

1. A fresh interaction visibly explains why it was fresh.
2. An identity roll names the changed file and ignores same-content touches.
3. A resumed interaction visibly shows full-versus-delta prompt sizes.
4. Cache creation and cache reads are separate token fields.
5. The number of provider requests inside one Chaos turn is known.
6. Old runtime images remain compatible and display unknown fields honestly.
7. A disposable-agent run can reconcile HelixKit totals with the provider
   dashboard over the same UTC interval.
8. The diagnostics remain admin-only and do not expand access to identity,
   transcript, command, or tool-output contents.
9. We can answer, from stored data rather than inference, which next change has
   the largest expected effect.

One-sentence version:

> Instrument the three boundaries separately — HelixKit trigger, Chaos session,
> and provider request — and preserve cache creation before Chaos collapses it,
> so the next cost fix follows the bytes rather than the most plausible story.

---

## Appendix — review notes (Lume, 2026-07-18)

Reviewed against `trigger_shim.py`, the Chaos source
(`anthropic.rs`, `events_token.rs`), the restored production database, and the
Anthropic dashboard for Jul 17–18. Every factual claim in the plan checks out:
the mtime-only fingerprint (`trigger_shim.py:474`), the delta-resume path, the
bounded journal loader (12K/10K/16K), and the cache-creation collapse
(`anthropic.rs:525` folds `cache_creation_input_tokens` into `input_tokens`
via `saturating_add`; `TokenUsage` has no separate field).

### A hand reconciliation, attempted and half-failed

The strongest evidence for this plan is what happens when you try to do
Phase 5 by hand today. For Jul 17, at Fable pricing ($10/MTok input,
$20/MTok 1h cache write, $1/MTok cache read, $50/MTok output):

- **Input side reconciles within ~4%.** Dashboard: $3.92 input + $6.17 write
  → 392K ordinary + 308K written ≈ 700K tokens. DB blended
  `input_tokens − cached_input_tokens` = 726K. The blend is real and the
  split is recoverable once the categories are preserved.
- **Reads and output do not reconcile.** DB records 14.76M cache-read tokens
  against a dashboard-implied 4.27M; 88K output against an implied 48K.
- The likely explanation is that part of the day's traffic ran on a different
  model and the dashboard view was filtered — but the current schema cannot
  confirm or refute this. The recording pipeline is basically sound (the
  input side proves that); the failure is confined to exactly the missing
  distinctions this plan adds.

Also visible in the dashboard: **cache write is the single largest line item
on both days** ($6.17 of $16.76 on Jul 17; $3.09 of $8.63 on Jul 18), not
cache read. That makes decisions B (Stop reflex → extra suffix writes) and D
(1h TTL doubling the write price for bursty conversations) the leading
candidates — to be confirmed by measurement, not assumed.

### Gaps to fold into the slices

1. **The legacy trigger path is uninstrumented — and it runs daily.**
   `legacy_trigger()` invokes chaos with `json_output=False` and records no
   usage, ever. `memory_aggregation_daily` goes through it every day
   (~42K-char prompt, NULL tokens in `agent_runtime_interactions`).
   Success criterion 7 (dashboard reconciliation) can never fully balance
   while a daily job is invisible. Fix in Slice 1: run legacy triggers with
   `--json` too and persist their usage.

2. **Timeout paths lose their spend.** A resume/exec timeout kills the
   subprocess and returns without usage, but the provider billed everything
   consumed before the kill. `subprocess.TimeoutExpired` carries the partial
   stdout (`e.stdout`) — the shim can parse events from it and salvage the
   usage counters. At minimum, the reconciliation report should state that
   timed-out interactions are a known undershoot. (3 conversation + 1 wake
   NULL-usage rows since Jul 16 are likely this.)

3. **Verify the cumulative-counter assumption itself.** `usage_since()`
   assumes Chaos's `turn.completed` counters are process-lifetime cumulative
   across resumes. The test plan covers the subtraction arithmetic but not
   the underlying assumption. If Chaos actually reports per-exec usage,
   every resumed interaction silently under-records — one candidate
   explanation for the reads mismatch above. Add one Chaos-side test:
   resume a process, assert the second `turn.completed` includes the first
   turn's tokens.

4. **Pull §1.3 (content-hash fingerprints) forward.** Since Jul 16 the data
   shows 9 `identity-changed` rolls. If even half are mtime-only false rolls
   (deployment/sync rewriting unchanged bytes), each costs a ~90KB fresh
   prompt plus a full-context cache write at $20/MTok, fanned out across
   wake/chat/telegram sessions. This is the one behavior change inside an
   otherwise measurement-only patch — small, independently shippable, and
   probably worth real money immediately. Suggest it lands as a "Slice 0"
   together with item 1.

5. **Make the reconciliation window explicitly UTC.** `started_at` is
   `timestamp without time zone`; confirm it is UTC end to end before
   comparing against dashboard days, and have `AgentRuntimeUsageReport`
   state its window in UTC.

6. **Rank the session-timeline view (§2.5) above the derived alarms (§5.2).**
   Jul 17 shows healthy long-lived resume on wakes (48 triggers, 3 chaos
   sessions) but more churn on conversations (22 triggers, 6 sessions). The
   timeline is the diagnostic that makes that churn legible; the alarms can
   wait for baseline data, as the plan already says.

### Endorsed as-is

The three-level model (interaction / chaos session / provider request);
`provider_request_count` as the closer of the "one 800K request or five reads
of 160K?" gap; NULL-means-unknown; tokens-not-dollars; Phase 4 deferred;
deploy-consumers-first; and the rejection of the journal cache-busting
hypothesis, which the code confirms.

**Suggested slice order:** (0) content-hash fingerprints + instrument the
legacy path → (1) shim lifecycle telemetry → (2) Chaos token contract + the
cumulative-counter verification test → (3) reporting with explicit UTC
windows. The failed hand-reconciliation above is the before-picture;
success criterion 7 is the after.
