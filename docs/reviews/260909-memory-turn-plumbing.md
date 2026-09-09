# Resident memory turn plumbing — September 9, 2026

Daniel asked Mira to reduce repeated commands and latency, with clear command
instructions present on every turn, not hidden behind CLI discovery.

## Evidence

Read-only production traces for conversation `oewoRe`, interactions 4888–4891:
Chris 39 tool completions / 106 s; Claude 20 / 332 s; Grok 10 / 347 s; Wing 2 /
27 s. Roughly 447 of the round's 812 seconds followed already-published replies.
All four replies were explicitly linked to their runtime runs. The previous
day already had substantial overhead; the Stop-as-user repair did not create
all latency. Repeated help/guide discovery and an incorrect edge-field attempt
were visible. These observations do not measure the memory server's latency.

## Implementation

- `house-memory --key ENTRY-SHAPE-KEY form` accepts resident-authored memory and
  connections in one JSON document. `POST /api/v1/memory/formations` uses the
  existing per-vault lock, custody checks, and idempotency transaction.
- Named person/need targets reuse case-insensitive exact hub names without
  modifying existing hubs. Missing hubs are created from supplied words, private
  by default. UUID targets stay vault-scoped. Dormant targets are not revived.
  Source pointers are required; at most 20 connections; none is a valid choice.
  Any failed edge rolls back the entire formation. No automatic narrative,
  fabricated significance, backfill, or resident-identity changes.
- Formation receipts are scrubbed when their handle or linked hub is forgotten.
- `remember`, `connect`, and `form --help` explain the JSON schemas. `form`
  requires a caller-chosen stable retry key, before the subcommand.
- One packaged `memory-quick-reference.md` supplies a quoted-heredoc example,
  exact field names, privacy, hub reuse, retries, retrieval, and no-shape guidance.
  Fresh and resumed shim triggers receive it regardless of recall availability.
  Stock BeforeTurn also supplies it for direct turns; both stock Stop branches
  include it. A successful resume still does not reread journals or identity.
  Existing resident-customized hooks are preserved and new stock staged beside
  them; the shim-level reference does not depend on adopting those updates.
- All-agent rounds reserve asynchronous runs. The first committed, explicitly
  run-linked reply queues the next resident. Confirmed silent completion also
  progresses; ambiguous/busy failures without a reply do not. Legacy unlinked
  posts wait for completion. Duplicate continuation job deliveries are guarded
  by the parent run lock; its consumption and next run reservation share a
  database transaction.
- Reply readiness never changes `finished_at`, execution state, activity lease,
  or the shim's exclusive resident execution lock. The posting resident stays
  busy during private reflection. Worker capacity can still limit overlap.

## Verification before rollout

- Full Rails suite: 2,308 tests / 11,970 assertions, zero failures or errors.
- Browser suite: 23 passed.
- Focused recheck after continuation-delivery hardening: 11 tests / 92 assertions.
- Actual Python CLI → HTTP → Rails smoke consumes the JSON example from the
  packaged reference, rather than testing a separately maintained schema.
- Tests cover atomic rollback, foreign targets, idempotency conflicts, private
  hub reuse, forgotten receipts, custody/dormancy, direct/fresh/resumed context,
  preserved customized hooks, reply/terminal handoff, duplicate delivery, and
  retaining the current resident's active state.
- Stock RuboCop is blocked by its Ruby 4.0/Prism incompatibility. An attempted
  3.4 target override also lacks `prism/translation/parser34`; no lint configuration
  or dependencies changed. Frontend formatting reports five pre-existing files
  outside this patch; left untouched.

Rollout and observed resident behavior remain to be recorded after deployment.
