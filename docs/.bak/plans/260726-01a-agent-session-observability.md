# Durable observability for hosted-agent sessions

**Date:** 2026-07-26
**Status:** Proposed for review by Lume
**Related:** `docs/plans/260616-01d-persistent-chaos-sessions.md`

---

## 1. Summary

Extend HelixKit's hosted-agent observability from one aggregate record per
trigger into a durable, privacy-conscious trace that can explain why a session
was expensive.

The immediate Sessions UI now displays the diagnostic output and lifecycle
metadata already stored on `AgentRuntimeInteraction`. That is useful for
identifying an expensive trigger, but it cannot explain the work inside it. One
HelixKit trigger may cause many provider requests because the model reasons,
uses tools, retries, resumes, or falls back to a fresh Chaos process.

The most important missing abstraction is therefore a **provider-call ledger**:
one structured record for every billable model invocation, linked to its
HelixKit interaction and Chaos process.

Complete raw runtime traces should also be retained for short-term diagnosis,
but outside the primary relational payload. The database should hold searchable
metadata and bounded previews; compressed trace artifacts should hold the
complete event stream under explicit authorization and retention rules.

---

## 2. Evidence from production

On 2026-07-26, production contained:

- 667 `AgentRuntimeInteraction` records;
- 647 records with stdout and 350 with stderr;
- 201 stdout values and 344 stderr values at the runtime's 4,000-character
  capture ceiling;
- 488 complete invocation prompts, containing about 10.5 million characters.

Fable alone had 25 interactions between 2026-07-22 and 2026-07-26:

- 24 interactions with complete invocation telemetry;
- 247 known provider requests;
- approximately $54.23 in estimated API cost;
- 9 full prompts and 15 delta prompts;
- 22 of 24 stdout values at the 4,000-character ceiling.

The current records show which triggers were expensive and whether caching or
session resumption was working. They do not show which of Fable's roughly ten
provider calls per instrumented trigger consumed the cost or what caused each
additional call.

---

## 3. Goals

1. Attribute tokens and estimated cost to each individual provider request.
2. Explain the sequence of model calls, tool activity, retries, and session
   transitions within one HelixKit trigger.
3. Preserve the complete final agent diagnostic message independently of noisy
   process output.
4. Make full raw traces available to authorized operators for a limited time.
5. Keep normal Sessions pages fast and bounded.
6. Avoid turning sensitive runtime output into an indefinitely retained,
   broadly serialized log archive.

## 4. Non-goals

- Reconstructing historical per-call data from aggregate interaction columns.
- Storing provider request or response bodies by default.
- Persisting complete tool results in relational columns.
- Exposing raw traces through ordinary agent, chat, or API serializers.
- Replacing provider billing statements with HelixKit estimates.
- Building a general-purpose distributed tracing platform.

---

## 5. Design principles

### 5.1 Record structure before volume

The first priority is not a larger stdout field. A 100,000-character log still
cannot reliably answer which provider request cost $4 or whether it was a
retry. Structured per-call telemetry is more valuable than undifferentiated
output.

### 5.2 Separate operational metadata from sensitive artifacts

Relational records should contain the fields needed to search, aggregate, and
render a timeline. Complete raw JSONL, stdout, and stderr belong in a compressed
artifact with a separate authorization and retention boundary.

### 5.3 Unknown is not zero

Missing usage, cost, or lifecycle fields must remain explicitly unknown.
Reports must not substitute zero when an older Chaos image or unsupported
provider did not supply telemetry.

### 5.4 Capture at the source

Chaos owns provider calls and tool execution, so Chaos should emit the canonical
events. The HelixKit shim may envelope, redact, and forward them, but should not
infer provider-call boundaries from human-readable output.

---

## 6. Proposed data model

### 6.1 `agent_runtime_provider_calls`

Create one row for each provider request:

| Field | Purpose |
|---|---|
| `agent_runtime_interaction_id` | Parent HelixKit trigger |
| `agent_id` | Direct account-scoped querying and retention |
| `sequence` | Stable order within the trigger |
| `attempt` | Retry number for one logical turn |
| `chaos_process_id` | Chaos process that issued the request |
| `chaos_turn_id` | Optional Chaos-native turn identifier |
| `provider_request_id` | Provider request ID when reported |
| `provider` / `model` | Runtime selection |
| `started_at` / `finished_at` / `duration_ms` | Timing |
| `outcome` | `completed`, `failed`, `cancelled`, `timed_out` |
| `stop_reason` | Provider/Chaos completion reason |
| `retry_reason` | Rate limit, transport error, invalid tool result, etc. |
| token columns | Ordinary input, cache write/read, output, reasoning |
| `estimated_cost_usd` | Price snapshot applied to this call |
| `pricing_source` / `pricing_version` | Explain the estimate |
| `tool_call_count` | Calls requested by this provider response |
| `preceding_event_kind` | Trigger, tool result, retry, compaction, continuation |
| `telemetry_schema_version` | Compatibility and trust |
| `usage_complete` | Whether the row is safe to aggregate |
| `metadata` | Small provider-specific, non-secret fields |

Add a unique index on:

```text
[agent_runtime_interaction_id, sequence, attempt]
```

Index agent/time, provider/model/time, and provider request ID.

Do not store prompts, completions, authorization headers, or full provider
responses in this table.

### 6.2 Structured runtime events

Add `agent_runtime_events` only if the provider-call ledger cannot carry the
timeline cleanly. Candidate event kinds:

- `provider_request_started`
- `provider_request_completed`
- `tool_call_started`
- `tool_call_completed`
- `agent_message_completed`
- `retry_scheduled`
- `session_resumed`
- `session_rolled`
- `compaction_completed`
- `process_completed`

Each event should contain:

- parent interaction;
- monotonic sequence;
- Chaos process ID;
- timestamp and duration where applicable;
- event kind;
- bounded, redacted metadata;
- optional byte counts and content hashes.

Avoid storing complete tool arguments or results by default. Record tool name,
success/failure, duration, input/output byte counts, and a redacted summary.

### 6.3 Complete final diagnostic message

Add a dedicated `final_agent_message` text column or associated record on
`AgentRuntimeInteraction`.

This value should come from the completed Chaos `agent_message` event and should
not be subjected to the stdout/stderr tail limit. It is the agent's diagnostic
conclusion, not the raw process log.

Keep the existing bounded stdout/stderr previews for fast UI display.

### 6.4 Trace artifacts

Store one compressed artifact per HelixKit interaction containing:

- raw Chaos JSONL;
- complete stdout;
- complete stderr;
- a small manifest with schema version, byte counts, checksums, and redaction
  status.

Use Active Storage or a purpose-built object-storage service rather than a
database text column. The `AgentRuntimeInteraction` should store artifact
availability, byte counts, checksum, creation time, expiry time, and redaction
version.

The artifact is diagnostic evidence, not ordinary application data. It must not
be loaded by `as_json`, Inertia props, synchronization broadcasts, or cost
reports.

---

## 7. Runtime telemetry contract

Extend Chaos JSON events with a versioned provider-call envelope. A completion
event should be sufficient to create one ledger row without parsing prose:

```json
{
  "type": "provider_request.completed",
  "telemetry_schema_version": 2,
  "sequence": 4,
  "attempt": 1,
  "process_id": "...",
  "turn_id": "...",
  "provider_request_id": "...",
  "provider": "anthropic",
  "model": "claude-fable-5",
  "started_at": "...",
  "finished_at": "...",
  "duration_ms": 8420,
  "outcome": "completed",
  "stop_reason": "tool_use",
  "preceding_event_kind": "tool_result",
  "tool_call_count": 2,
  "usage": {
    "scope": "provider_request",
    "complete": true,
    "uncached_input_tokens": 1200,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 84000,
    "output_tokens": 310,
    "reasoning_output_tokens": 0
  }
}
```

The shim should forward supported events without silently normalizing unknown
future schemas into the current schema. Unsupported versions remain available
in the raw artifact and mark the interaction's detailed telemetry incomplete.

The existing trigger-level usage envelope remains useful as a reconciliation
total. HelixKit should compare:

```text
sum(complete provider-call rows) == trigger-level usage
```

and record a reconciliation state of `matched`, `mismatched`, or `unknown`.

---

## 8. Redaction and authorization boundary

Raw traces may contain conversation text, identity context, shell output,
downloaded documents, filesystem paths, and accidentally printed credentials.

Before upload, redact at least:

- HelixKit bearer tokens;
- provider API keys;
- authorization and cookie headers;
- known environment-secret values;
- common secret assignment formats;
- private URLs containing embedded credentials.

Redaction must happen before an artifact leaves the hosted-agent container when
practical. HelixKit should apply a second defensive redaction pass before
storage.

Authorization:

- account members may see the existing bounded Session diagnostics;
- complete artifacts should initially be site-admin only;
- artifact access should use a dedicated controller action, not a raw storage
  URL embedded in page props;
- every view/download should be audit logged;
- artifact deletion follows agent/account deletion immediately.

Do not assume that "debug output" is safe merely because the user owns the
agent. The explicit route boundary should make later relaxation a deliberate
product decision.

---

## 9. Retention

Recommended initial policy:

| Data | Retention |
|---|---|
| Provider-call ledger | Same as the parent interaction |
| Structured event metadata | Same as the parent interaction, subject to size review |
| Final agent message | Same as the parent interaction |
| Raw trace artifact | 30 days |
| Existing stdout/stderr preview | Same as the parent interaction |

Make raw-trace retention configurable. A daily cleanup job should purge expired
artifacts and record `trace_purged_at` without deleting the aggregate
interaction or provider-call ledger.

Before enabling longer retention, measure production artifact volume and review
whether traces contain material that should never have been persisted.

---

## 10. Sessions UI

Keep the current paginated Sessions card as the ordinary account-facing view.
Extend its diagnostic section with:

1. provider-call count and total known cost;
2. a compact ordered table of provider calls;
3. latency, token categories, cache ratios, stop reason, retry status, and
   preceding event kind;
4. an explicit warning when calls or usage are unknown;
5. the complete final diagnostic message;
6. a site-admin-only `Download full trace` action while the artifact exists.

Do not include raw artifacts or full provider-call metadata in every Sessions
index response if payload size becomes material. A dedicated account-scoped
interaction detail endpoint can load the expanded timeline on demand.

The admin runtime report should aggregate the provider-call ledger and expose
reconciliation mismatches. Trigger-level totals remain the fallback for older
interactions.

---

## 11. Delivery sequence

### Phase 1: Provider-call ledger

1. Define Chaos telemetry schema version 2.
2. Emit one event per provider request, including failed attempts.
3. Add `AgentRuntimeProviderCall`.
4. Persist supported events while recording the parent interaction.
5. Reconcile call totals against trigger totals.
6. Add model, service, and shim contract tests.
7. Add provider-call details to the admin runtime report.

This phase provides the greatest cost-debugging value and should ship before raw
trace storage.

### Phase 2: Final message and ordered event metadata

1. Persist the complete final `agent_message`.
2. Decide whether a general `AgentRuntimeEvent` table is warranted or whether
   bounded tool/retry fields can remain attached to provider calls.
3. Add an on-demand interaction detail view in Sessions.

### Phase 3: Raw trace artifacts

1. Add the trace manifest and storage association.
2. Implement container-side and server-side redaction.
3. Compress and upload traces after each trigger.
4. Add site-admin download/view actions with audit logging.
5. Add expiry and cleanup jobs.
6. Measure storage, upload latency, and redaction failures before enabling in
   production by default.

### Phase 4: Operational refinement

1. Add alerts for telemetry reconciliation mismatches.
2. Add per-agent/provider cost anomaly views.
3. Consider account-configurable retention and access only after the admin
   workflow is stable.

---

## 12. Failure handling

- Failure to persist provider-call telemetry must not fail the agent's visible
  response.
- Failure to upload a raw trace should set an explicit artifact error state and
  retain the ordinary interaction record.
- A provider request that times out or fails before reporting usage still gets
  a ledger row with unknown usage.
- Duplicate delivery must be idempotent under the interaction/sequence/attempt
  unique key.
- Unsupported event schemas must not be interpreted as zero usage.
- Redaction failure should prevent raw artifact upload rather than upload an
  unredacted trace.

---

## 13. Tests and acceptance criteria

### Runtime contract

- Multiple provider requests in one trigger produce ordered, distinct events.
- Retries and fresh fallbacks retain both billable attempts.
- Failed requests retain timing and outcome with unknown usage where necessary.
- Invocation and provider-call totals reconcile for supported telemetry.

### Rails persistence

- Provider-call rows are idempotent and account scoped.
- Unknown token fields remain null.
- Raw artifacts never appear in ordinary serializers or broadcasts.
- Artifact access requires the intended authorization and is audit logged.
- Cleanup purges expired artifacts without deleting ledger rows.

### UI

- Sessions displays every stored interaction through pagination.
- Provider calls are loaded and ordered correctly.
- Unknown/mismatched telemetry is visibly distinguished from zero.
- Complete final messages are not clipped at 4,000 characters.
- Raw traces are only available through the dedicated authorized action.

### Production acceptance

For a newly instrumented Fable interaction, an operator can answer:

1. How many provider requests occurred?
2. Which request cost the most?
3. Which requests followed tool results or retries?
4. How much input was ordinary, cache-written, and cache-read?
5. Did provider-call totals reconcile with the trigger total?
6. What was the complete final diagnostic message?
7. Is a full redacted trace available, and when will it expire?

---

## 14. Open questions for review

1. Can Chaos emit a stable event for every provider request across all supported
   providers, including retries performed below its current abstraction?
2. Is a general event table justified, or should Phase 1 remain deliberately
   limited to provider calls?
3. Should raw artifacts be stored through Active Storage or a smaller
   runtime-trace service with explicit expiry?
4. Which redaction library or shared secret-filter implementation should be
   canonical between Python and Rails?
5. Is 30 days the right initial artifact retention?
6. Should account owners eventually gain raw-trace access, or should complete
   traces remain an operator-only diagnostic surface?
7. Should full invocation prompts retain their current long-term lifecycle, or
   should they move behind the same stricter artifact boundary?
