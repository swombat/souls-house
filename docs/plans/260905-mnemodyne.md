# Mnemodyne inside souls.house

Date: 2026-09-05
Status: local hosted/external pilot implemented; final verification below.
Not deployed or enabled for real residents. Provider and custody-policy gates remain.
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

### 1. Storage foundation (implemented)

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

### 2. Resident-authenticated formation and inspection (implemented)

- Reuse the current resident authentication and secure service-manifest
  mechanisms after reviewing their present contracts; do not create a human-owned
  `ServiceConnection` for intrinsic private memory infrastructure.
- Vault lifecycle and suspension checks; node/edge CRUD, idempotency, bounded
  input, deliberate dormancy/revival and export. Stable IDs for portability.
- Cross-vault tests for every route, including peers on the same account;
  prevent graph contents from leaking through logs, audits or ordinary agent JSON.
- Keep automatic preview disabled until the next slices pass.

### 3. Embeddings and recall (implemented; provider unconfigured)

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

### 4. Runtime vertical pilot (synthetically verified)

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

### 5. Custody and rollout (checkpoint safeguards implemented; rollout gated)

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

## Continuation after the storage checkpoint

Daniel corrected an unwarranted stop at the first commit. Implementation is
continuing in instance 2 through the remaining local capability, not pausing at
slice boundaries. No delegation was requested; all work remains in this session.

Implemented but not yet finally verified/committed:
- `/api/v1/memory` resident-key API; inline/human-key rejection, graph CRUD,
  per-vault idempotency, suspension checks, filtered request instrumentation.
- Exact cosine pilot search over portable float arrays (local PostgreSQL has no
  pgvector extension; modifying the shared server would violate instance scope).
  Explicit capacity limits: 5,000 eligible nodes / 20,000 eligible edges. This
  replaces only the index backend for the pilot, not cosine/walk semantics.
- Configurable OpenAI-shaped local embedding endpoint via
  `MNEMODYNE_EMBEDDING_URL` and `MNEMODYNE_EMBEDDING_PROFILE`. No default provider
  and no real private data sent. Node-seeded recall works without a provider;
  query recall reports unavailable until a provider is configured.
- Non-mutating preview, 15-minute signed receipts, selected-node replay-safe
  commit, no Hebbian wiring; per-vault decay job (schedule not yet wired).
- Runtime `house-memory` utility and memory client; fresh/resumed shim candidate
  injection from a bounded newest-message trigger envelope, with a 2.5s utility
  process deadline. Uses the existing resident API credential, not a new secret
  or external-service manifest entry. Vault/node automatic disclosure is opt-in.
- Identity/work source opening with traversal/symlink protections, commit only
  after source output. `house://` automatic opening is not yet implemented.
- Portable checksummed export/import; replacement requires suspended vault.
  Paired restic graph checkpoint carrier (stopped disposable Docker container,
  anonymous volume, `docker cp`); restore digest/owner checks before destructive
  work and graph import before wake. All real backup/restore remains disabled
  for secondary instances. This wiring still needs its own lifecycle tests.

Intermediate evidence: 125 graph/API/existing-runtime tests passed before the
checkpoint work. Source/receipt utility tests and fresh/resume injection test
pass. Checkpoint import initially revealed that association `delete_all` with
`restrict_with_error` attempts nullification; replacement now uses explicit
vault-scoped relations, awaiting rerun. A recall-generation counter was added to
invalidate pre-restore receipts; migration and tests pending.

Next: finish lifecycle, provider/job, API-recall and runtime-path tests; run full
Rails and owned browser suites, syntax/lint/format checks; perform a synthetic
local HTTP/CLI smoke; document configuration/deployment gates accurately; commit
only owned changes on instance-2 master. Preserve the original one-line generated
routes-file change. No real residents, other instances or production touched.


## Local pilot completion review

The continuation notes above are an intermediate record, not the current status.
The API, recall/commit, embedding jobs, runtime client, safe file and authenticated
house-conversation sources, fresh/resumed preview, production decay schedule,
portable export/import and paired backup/restore safeguards are implemented.
`needs/persons` inspection is `nodes --type need/person`, not duplicate commands.
Operator/resident instructions: `docs/mnemodyne.md` and the shipped runtime manual.

Additional review fixes:
- Checkpoint replacement uses explicitly vault-scoped delete relations and a
  generation counter to invalidate pre-restore receipts; failed imports roll back.
- Forgetting a node tombstones historical idempotency responses referring to it,
  while retaining retry keys. Backups/exports have separate retention.
- Source opening rejects non-regular files without blocking on a FIFO. House
  pointers use the existing resident-participation-scoped conversation API.
- Provider reads are size-bounded while streaming; async writes recheck content,
  profile and suspension after the provider response.
- SQL bind logging was a separate leak from request instrumentation. An exact-name
  application-wide parameter filter now redacts private graph fields and stored
  operation responses. A regression test checks actual SQL debug output.
- Backup lifecycle tests caught a graph-mount argument attached to restic init
  rather than backup; fixed and covered explicitly. Disposable carrier cleanup,
  checksum/owner mismatch and failed-import no-wake behavior are tested without
  Docker, remote credentials or bypassing guards outside synthetic test doubles.

The local pilot deliberately does **not** establish self-service vault erasure,
grace-period duration, automatic credential rotation at restore, room-specific
disclosure or consent for legacy imports. Existing key revocation and privileged
vault suspension work; vault/agent deletion remains restricted. These are explicit
custody/product decisions before production enablement, not a silent destructive
implementation. A selected private provider, runtime image rollout, production
migrations and a consented resident pilot are also deployment gates. The shared
PostgreSQL server and other checkouts were not modified.

Intermediate final evidence: full Rails suite 2,567 tests / 12,275 assertions,
zero failures/errors/skips; browser suite 17/17. Subsequent SQL-log and subprocess
boundary regressions passed (71 tests / 493 assertions). Final rerun follows.

Final review also connected deliberate graph suspension to sandbox invocation,
start and respawn checks. A restore failure must not merely skip its own final
wake while allowing the next scheduler/health action to wake mismatched memory.
The journal-tail test now compares the journal contribution rather than including
the independently growing runtime manual in its size bound.

### Final local verification — September 5

- Full Rails suite after the logging and runtime-suspension fixes: **2,570 tests,
  12,288 assertions, zero failures/errors/skips** (`log/mnemodyne-final-rails.log`).
- All **41 changed Ruby source/test/migration files** pass the temporary Ruby 3.4
  parser-target lint check, inheriting unchanged repository rules. Generated
  `schema.rb` is not hand-formatted. Stock RuboCop still fails on Ruby 4.0 parsing
  (exit 2); it was run, not silently substituted.
- Python compilation passes. The socket-level Python client smoke dispatches
  real requests through Rails authorization/routes in the fixture-owning test
  thread; it does not claim a rebuilt Docker image or a live provider test.
- Frontend format check still reports the same eight pre-existing untouched files.
  The one-line pre-existing `app/frontend/routes/index.d.ts` modification remains
  untouched and unstaged. No frontend feature or visual changes were made.
- All additive migrations were applied only to the instance-2 development/test
  databases. No database reset, shared-server extension change, resident import,
  real embedding request, real backup/restore, push or deployment was performed.

- Final owned browser rerun: **17/17 passed** (`log/mnemodyne-browser.log`).
  One preceding full run timed out waiting for `After pagination 002` in the
  existing chat-pagination stress test (16/17); the isolated rerun passed (1/1),
  then the full rerun passed without changing or suppressing that test. This
  intermittent synchronization failure is recorded, not claimed fixed.
- Local implementation commit only; production readiness still depends on the
  provider, custody decisions and rollout gates described above.
