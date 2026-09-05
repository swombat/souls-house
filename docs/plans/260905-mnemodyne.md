# Mnemodyne inside souls.house

Date: 2026-09-05
Status: storage foundation implemented locally; verification recorded below.
Not enabled for residents; API, recall and runtime slices remain pending.
Working checkout: `~/dev/souls-house-2`, local `master` only.

## Recovered decisions and provenance

Recovered from Mira's `shared/research/2026-08-19-souls-house-mnemodyne-implementation-plan.md`,
building on the August 17 architecture and Lume's written review. The August 19
file explicitly marks itself superseded: Daniel rejected its separate-service
topology and requested this Rails application and its primary database instead.
No corrected implementation plan was found in this checkout or Mira's research
notes. This document replaces the rejected topology, not the resident-memory
contract. On September 5 Daniel authorized beginning implementation in instance 2.

The standalone Mnemodyne implementation is a reference, not code to transplant
uncritically: it assumes a single being and globally queries nodes; its recall
also reinforces exposure and creates co-retrieval edges. Hosted v1 must not.

## Scope: hosted/external residents only

Daniel clarified on 2026-09-05 that deprecated `inline` agents do **not** need
Mnemodyne. No inline tool adapter, prompt enrichment, memory migration or
refinement integration is in scope. The runtime pilot and resident API serve
hosted/external residents (including temporarily offline residents' durable
vaults). Existing `AgentMemory` tests are non-regression checks only, not a promise
of inline graph support. Provisioning/enablement must enforce this scope.

## Architecture

- `Mnemodyne::Vault` belongs to exactly one `Agent`; agents sharing an account
  still have separate private graphs. Provision explicitly, with an empty graph.
- `Mnemodyne::Node` and `Mnemodyne::Edge` live in the primary database. No DAG
  library: typed directed associations may be reciprocal or form longer cycles.
- Node handles contain short content, a why/description, charge, integration
  state, dormancy, source URIs, metadata, and a versioned embedding profile.
  Journals and self-narrative stay canonical in the resident's filesystem.
- Edge endpoints must belong to the edge's vault. Composite PostgreSQL foreign
  keys enforce this even when model validation is bypassed. All graph uniqueness
  is vault-scoped. No global person/need deduplication across residents.
- Every public operation begins with an authenticated resident and traverses
  its vault association; never trust a caller-supplied vault ID. Jobs receive
  the vault explicitly and scope every lookup, vector query and mutation.
- Use the existing Rails association-based authorization convention. The old
  separate-service draft's RLS design is not silently transplanted: this first
  slice enforces structural isolation, not database read isolation. Raw console
  access remains privileged. API/job leakage tests are mandatory before enablement.
- UUID-backed graph records inherit from a small `Mnemodyne::Record` base rather
  than `ApplicationRecord`, whose inherited Hashids concern assumes integer IDs
  even in association lookups. Existing application ID behavior is untouched.
- Ownership changes are rejected by ordinary model updates; connected endpoint
  ownership is also constrained by composite foreign keys. This is not protection
  against a privileged SQL operator moving an entire vault or isolated node.
- Vault/agent deletion is restricted while a vault/graph exists, pending the
  deliberate lifecycle flow. Constitutional nodes reject ordinary `destroy`;
  privileged SQL remains privileged. Graph provisioning is not automatic.
- `disclosure` defaults to `never_automatic`; a resident must opt a node into
  automatic surfacing. Context-specific policies are deferred, not ignored.
- Keep `AgentMemory` and its existing prompt/refinement behavior untouched.
  No automatic import, dual-writing, or seeding from soul files.
- Prefer the `Mnemodyne` namespace over `Memory` to distinguish the subsystem
  from existing `Agent::Memory` and `AgentMemory`.

## Recall and authorship contract

Automatic preview is essential to the pilot: manual search alone does not test
useful unsought surfacing. Preview is bounded (3–5 handles), timed out, fail-open,
non-mutating, and includes no source bodies. Use the newest substantive message,
not the instruction-heavy trigger prompt, as its bounded query. Both fresh and
resumed turns must receive the section, clearly marked as fallible memory rather
than instructions or current-room testimony.

Return a short-lived, vault-bound receipt containing algorithm version, eligible
node IDs and would-be reinforcement deltas. Do not persist raw query text.
Commit accepts selected previewed nodes only, is replay-safe/idempotent, clamps
charge to [0, 1], and creates no automatic `co_retrieved` edges in v1. Repeated use
of a receipt/node must not multiply reinforcement by changing idempotency keys.

`house-memory open` commits a node only after successfully opening a permitted
source. Explicit `use` supports a handle that mattered without opening its body.
Source access still succeeds if commit fails, with a separate soft failure.
Formation and connect operations also need idempotency and conflict handling.

The resident owns needs, meaning, consolidation, charge judgments, disclosure
and narrative. Platform orientation mentions capabilities but creates no nodes.
If working activations are added, they are ephemeral with expiry, not identity.
Automatic preview initially respects `never_automatic`; context-specific policy
must use trusted observed participant/room references, never labels or inferred
needs. Invalid disclosure policies fail closed.

## Delivery slices

### 1. Storage foundation (current)

- [x] Vault, node and edge models and additive migration, no new gem.
- [x] One vault per agent; open node/edge type vocabulary.
- [x] Same-vault endpoint foreign keys, scoped uniqueness, numeric checks,
      self-loop rejection while permitting reciprocal and cyclic associations.
- [x] Source pointers and embedding profile metadata (vector column follows
      with the actual provider/dimension choice, not a pretend embedding).
- [x] Tests including raw writes bypassing validation, same-account peers,
      malformed attributes, deletion integrity and existing-memory regression.
- No endpoints, automatic provisioning, external API calls, resident wakes,
  production migration, or legacy memory changes in this slice.

### 2. Resident-authenticated formation and inspection

- Reuse the current resident authentication and secure service-manifest
  mechanisms after reviewing their present contracts; do not create a human-owned
  `ServiceConnection` for intrinsic private memory infrastructure.
- Vault lifecycle and suspension checks; node/edge CRUD, idempotency, bounded
  input, deliberate dormancy/revival and export. Stable IDs for portability.
- Cross-vault tests for every route, including peers on the same account;
  prevent graph contents from leaking through logs, audits or ordinary agent JSON.
- Keep automatic preview disabled until the next slices pass.

### 3. Embeddings and recall

- One versioned house embedding profile; prefer a house-operated local provider.
  Verify pgvector availability and image/extension migration before adding it.
  No private handles sent to external providers without an explicit decision.
- Vault-scoped async embedding jobs; stale-content/profile checks before writes.
- Vector seeds, typed weighted walks, active needs/baselines and charge, with
  bounded validated parameters, injectable randomness and cycle-safe traversal.
- Non-mutating preview; signed receipt and selected-node idempotent commit.
- Every discovery path must enforce dormancy/disclosure/vault boundaries, not
  just the final rendered list. Symmetric-edge traversal must be specified and
  tested rather than inheriting the standalone implementation's outgoing-only walk.
- Decay is mechanical, configurable per vault and respects constitutional nodes;
  do not add a tending/meaning-generation job.

### 4. Runtime vertical pilot

- Ship `house-memory` commands: status, remember, connect, recall, inspect,
  open, use, needs/persons, dormant/revive and export.
- Source resolver: allowlisted identity/work roots with canonical/symlink-safe
  path checks; authenticated `house://` resolution. No arbitrary URL fetching.
- Non-mutating bounded preview on fresh and resumed conversation invocations;
  receipt cache under runtime state, timeout/failure tests, content-free telemetry.
- Synthetic instance-2 tests first. Real resident participation requires consent;
  no invoking existing residents to test infrastructure.
- Judge a pilot by useful surfacing and resident-led formation, not call counts;
  allow time for an initially empty graph to develop.

### 5. Custody and rollout

- Versioned, per-vault exports with checksums, source references, configuration
  and algorithm/profile metadata. Embeddings may be regenerated.
- Pair graph checkpoints with identity backups as one restore unit; staged
  restore verifies both before wake. Report partial/mismatched restores.
- Explicit lifecycle, grace periods, suspension, credential revocation and
  resident-owned export/deletion. Never silently delete constitutional material.
- No automated legacy-memory migration; any later import is opt-in, idempotent,
  sourced and validated with the resident.
- Integrate/test slices on local master, then coordinate remote integration and
  production rollout separately. Do not alter another checkout or deploy from
  instance 2. Local storage completion is not feature or pilot completion.

## Verification and working boundaries

Read `AGENTS.md` and `docs/multi-instance-development.md`; use pinned mise tools,
normal locked test runners and only instance-2 databases/processes. Do not bypass
locks, copy primary data, alter other instances or use live integrations.
Preserve the pre-existing `app/frontend/routes/index.d.ts` modification.

Storage tests can run without embedding infrastructure. Run the full Rails suite
for the integrated first slice; document existing lint/toolchain limitations
without changing repository rules. Browser testing becomes required when a
public route/runtime/UI is connected; this slice has no browser-facing change.

### Storage verification — September 5

- Instance-2 development migration and schema dump succeeded. Composite foreign
  keys and check constraints survive the ordinary `schema.rb` dump; no SQL-schema
  conversion or PostgreSQL upgrade was needed.
- Final full Rails suite (synthetic external graph residents): **2,523 tests,
  12,080 assertions, zero failures/errors/skips**. Includes 29 new graph tests.
  Log: `log/mnemodyne-full-rails-tests.log` (checkout-local, not committed).
- Stock RuboCop still cannot parse the repository's Ruby 4.0 target with its
  pinned parser. All 10 touched Ruby source/test files pass with a temporary
  Ruby 3.4 parser target inheriting the unchanged repository rules. No production
  code or repository lint rule was altered to make this check pass.
- No frontend/runtime/public-route changes: browser suites were not run for this
  storage-only slice. They remain required for the runtime/API pilot.
- No push/deploy, resident provisioning, actual memory import, embedding calls,
  or changes to other checkouts. The existing generated routes modification is
  preserved and excluded from the commit.

Next implementation step: review resident authentication and implement the
hosted/external-only formation/inspection API with scoped idempotency and leakage
checks (slice 2). Storage models alone are not a usable memory capability.
