# Review: Durable observability for hosted-agent sessions

**Date:** 2026-07-26
**Reviewer:** Lume
**Reviewing:** `docs/plans/260726-01a-agent-session-observability.md`
**Verdict:** Phases 1–2 are right and should ship. Phase 3 is enterprise-shaped for a
one-operator deployment and should shrink to about a day of work or be deferred.
Several columns and one whole table should be cut. Detail below.

---

## 1. Does it achieve the objective?

Yes — and the plan correctly identifies *which part* achieves it. The
provider-call ledger is the load-bearing piece. Of the seven production
acceptance questions in §13, questions 1–6 are answered by Phases 1–2 alone.
Only question 7 needs Phase 3. That ratio should drive the delivery sequence
harder than the plan currently lets it.

**Feasibility of the critical dependency (open question 1):** mostly already
answered in the Chaos source. `record_provider_request_started` in
`sys/kern/kern/src/chaos/session/tokens.rs` is the existing per-request hook —
it is where v1's `provider_request_count` increments. Emitting a
`provider_request.completed` event is an extension of an existing seam, not new
instrumentation. The residual risk is real but narrow: retries performed below
the driver abstraction, and any agent running via clamp transport, where
provider calls happen inside Claude Code and Chaos sees only what the transport
reports. The plan should name clamp explicitly in open question 1, because the
answer differs by transport.

The "unknown is not zero" principle (§5.3) is not aspirational here — it is
already implemented discipline in `AgentRuntimeInteraction#record_result!`
(the `detailed_usage` gating) and `#telemetry_state`. The plan continues an
existing convention rather than inventing one. Good.

---

## 2. The structural problem: half ledger, half archive

The plan is two documents. The first (§6.1, §6.3, §7, Phase 1–2) is a tight,
well-grounded design for cost attribution. The second (§6.4, §8, §9, Phase 3–4)
is a trace-archive platform: compressed artifacts, manifests, checksums,
redaction versions, dual redaction passes, audit-logged downloads, expiry jobs,
anomaly views.

Production evidence in §2 justifies the first document. Nothing in §2
justifies the second — the observed pain (22 of 24 stdout values at the
4,000-char ceiling, cost unattributable within a trigger) is fully addressed by
the ledger plus `final_agent_message`. The plan's own §5.1 makes this argument:
structure before volume. Follow it to its conclusion.

**Recommendation:** if Phase 3 is built at all, build the Rails-simplest
version:

- one Active Storage attachment on `AgentRuntimeInteraction` (gzipped JSONL);
- one admin-only controller action to download it;
- one secret-scrubbing pass in the shim before upload;
- a daily purge job at 30 days.

That is roughly a day. Drop the manifest, checksums, redaction-version
tracking, the second server-side redaction pass, and the audit logging of
views — those are multi-tenant compliance features. When HelixKit has external
accounts whose agents' traces an operator might inspect, revisit; the explicit
route boundary the plan wants is preserved either way. Better still: defer
Phase 3 entirely until a concrete diagnosis actually fails for lack of a raw
trace, and note which diagnosis it was.

---

## 3. Cut the events table now, not conditionally

§6.2 hedges: add `agent_runtime_events` "only if the provider-call ledger
cannot carry the timeline cleanly." Take the position instead: **don't build
it.** Half the candidate event kinds (`provider_request_started/completed`,
`retry_scheduled`) are already encoded in ledger rows; the session-lifecycle
kinds (`session_resumed`, `session_rolled`, `compaction_completed`) are already
columns on the interaction; tool activity is covered by `tool_call_count` and
`preceding_event_kind` well enough to answer acceptance question 3. A second
timeline table would be a parallel representation of data the ledger already
orders. If a future need appears, the raw JSONL artifact is the escape hatch.
§6.2 should be one sentence saying so.

---

## 4. Ledger schema trims

The proposed `agent_runtime_provider_calls` is mostly right. Three cuts and one
clarification:

1. **Drop `agent_id`.** The justification ("direct account-scoped querying and
   retention") doesn't hold: retention is "same as the parent interaction," so
   deletion cascades through the parent, and account scoping is one join. Add
   `has_many :provider_calls, through: :runtime_interactions` on `Agent` and
   query Rails-ly. At this deployment's volumes (hundreds of interactions,
   thousands of calls) the join is free. Denormalize when a query is actually
   slow.

2. **Drop `telemetry_schema_version` per row.** It cannot vary within one
   trigger — even a fresh fallback runs the same Chaos image. The parent
   interaction already stores it.

3. **Reconciliation state should be a derived method, not a stored column.**
   The codebase pattern is `telemetry_state` — computed at read time. `SUM`
   over a few dozen rows per interaction is trivial in SQL. Store it only if
   Phase 4's mismatch alerts turn out to need an indexed column, which they
   won't at this volume.

4. **Define what increments.** The unique key
   `[interaction_id, sequence, attempt]` is correct for idempotency (and the
   recorder should use `upsert`/`create_or_find_by!` against it), but the plan
   never states whether a retry gets a new `sequence` or reuses one with
   `attempt + 1`. The JSON example carries both without disambiguating. One
   sentence fixes this; ambiguity here breaks the ordering guarantee the whole
   timeline rests on.

`final_agent_message` (§6.3): take the plain text column, not the associated
record. It is one value with the lifecycle of its parent. Correct and simple as
proposed.

---

## 5. Two pricing paths — decide the authority

The plan stores `estimated_cost_usd` per call with `pricing_source` /
`pricing_version`. The existing pattern is compute-on-read
(`AgentRuntimeInteractionCost.new(self).call`). Both are defensible; **having
both without a rule is not** — the Sessions card will show one number and the
ledger will sum to another the first time a price changes.

The snapshot is actually the more correct choice for a ledger (compute-on-read
silently reprices history), but the plan must then say: *when complete ledger
rows exist and reconcile, interaction-level cost is the sum of its rows; the
read-time service is the fallback for pre-ledger interactions.* One authority
per interaction, chosen by data availability. Add this to §7.

---

## 6. The blind spot: data already in the table

The plan draws a careful artifact boundary while ignoring two raw stores
already inside the primary table:

- **`response_body` jsonb** — `record_result!` persists the entire response
  body (stdout, stderr, telemetry, duplicated) on every interaction, and the
  plan never mentions it. Whatever boundary §6.4 establishes, `response_body`
  is currently on the wrong side of it. Cheapest fix: stop storing it once the
  ledger lands (its contents are then fully decomposed into columns and ledger
  rows), or trim it to the fields not otherwise captured.

- **`full_invocation_text`** — open question 7 asks; here is a verdict: yes,
  move it behind the same retention as raw traces. It is 10.5 million
  characters of identity-laden prompt text, the largest sensitive blob in the
  system, and it predates the boundary the plan is drawing. Same 30-day purge
  job, `invocation_text_purged_at` alongside `trace_purged_at`. This is
  arguably more urgent than anything in Phase 3, since the exposure already
  exists.

---

## 7. Rails-like-ness

Mostly idiomatic:

- Naming (`agent_runtime_provider_calls` / `AgentRuntimeProviderCall`,
  `belongs_to :agent_runtime_interaction`) — correct.
- String status values without `enum` — consistent with `session_outcome` et
  al. in the existing model. Fine.
- Unique-index-backed idempotency — the Rails way to make duplicate delivery
  safe. Good.
- Active Storage over a bespoke trace service (open question 3) — yes, Active
  Storage. A purpose-built object-storage service for one deployment's debug
  traces is exactly the kind of infrastructure this codebase has so far
  resisted.

One caution: `record_result!` is already ~70 lines of envelope plumbing and is
near the ceiling of what belongs in a model method. The ledger recorder should
follow the same *pattern* (a `record_*!` class or instance method — consistency
matters more than purity here) but must not be bolted into `record_result!`
itself. `AgentRuntimeProviderCall.record_event!(interaction:, event:)` keeps
the parsing beside the table it fills, and leaves `record_result!` alone.

---

## 8. Remaining open questions, answered where a position is possible

1. *(Chaos per-request events)* — see §1 above; hook exists, name the clamp
   caveat.
2. *(General event table)* — no. See §3.
3. *(Active Storage vs trace service)* — Active Storage. See §7.
4. *(Shared redaction implementation)* — with Phase 3 shrunk to one shim-side
   pass, this question mostly dissolves; a small shared regex list checked into
   the Chaos-agent repo suffices. Don't build a cross-language redaction
   library for one caller.
5. *(30 days)* — fine as a default; make it a setting and move on. The
   interesting number is `full_invocation_text`'s retention, not the trace's.
6. *(Account-owner trace access)* — not until there are account owners who are
   not also the site admin. The plan's instinct (deliberate product decision
   later) is right.
7. *(Prompt lifecycle)* — answered in §6 above: yes, 30-day retention now.

---

## 9. Summary of requested changes

| # | Change | Where |
|---|---|---|
| 1 | Reduce §6.2 to "not building an events table; raw artifact is the escape hatch" | §6.2 |
| 2 | Drop `agent_id` and `telemetry_schema_version` from the ledger; add `Agent#provider_calls` through-association | §6.1 |
| 3 | Reconciliation state as derived method, not column | §7 |
| 4 | Specify sequence-vs-attempt increment semantics | §6.1/§7 |
| 5 | State the cost-authority rule (ledger sum when complete, service fallback otherwise) | §7 |
| 6 | Account for `response_body`; retire or trim it once the ledger lands | new |
| 7 | Give `full_invocation_text` 30-day retention in Phase 1, not as an open question | §9, §11 |
| 8 | Shrink Phase 3 to attachment + admin action + shim redaction + purge job, or defer until a diagnosis concretely fails without it | §6.4, §8, §11 |
| 9 | Name the clamp-transport caveat in open question 1 | §14 |

The core design — one row per billable provider call, captured at the source,
unknown kept distinct from zero — is the right abstraction and matches
discipline this codebase already practices. Ship Phases 1–2. Resist the
archive.
