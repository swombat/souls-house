# Mnemodyne — ready for Lume's review

**Historical initial packet.** Lume's review found substantive gaps; see
`260905-mnemodyne-lume-review.md` and the implemented response in
`260905-mnemodyne-review-followup.md`. In particular, Daniel subsequently required
automatic lifecycle reflexes, superseding this packet's opt-in boundary.

September 5, 2026. Implemented and verified in `souls-house-2`, local `master`.
**Not deployed, pushed, enabled for real residents or reviewed by Lume yet.**
This is the completed hosted/external v1 feature, not a proposed pilot.
Deprecated inline agents remain explicitly out of scope.

## Review range and reading order

The complete feature starts after `62da2e1`: foundation `6390aa0`, runtime/API
`5393d8d`, and the completion commit containing this packet. Review the whole
range, not only the last commit.

1. `docs/plans/260905-mnemodyne.md`: recovered provenance, Rails/main-database
   architecture and the final completion mandate. Earlier pilot entries are
   historical; the final verification section supersedes their readiness status.
2. `docs/mnemodyne.md`: resident-facing contract and commands.
3. `app/models/mnemodyne`, `app/services/mnemodyne`,
   `app/controllers/api/v1/memory`: vault scoping, graph, recall, selected-use,
   checkpoint and custody rules.
4. `agent-runtime/memory_client.py`, `trigger_shim.py`, `house-memory`: bounded
   source access, private receipts, fresh/resumed automatic preview.
5. `app/services/backup`, `app/jobs/backup/agent_restic_job.rb`,
   `app/services/agents/rotate_credentials.rb`: consistent paired snapshots,
   validation before replacement, suspended failures, rotated credentials.
6. `services/mnemodyne-embeddings`, deployment config and
   `docs/mnemodyne-deployment.md`: pinned private inference, release and rollback.
7. `test/integration/mnemodyne_local_smoke_test.rb`: executable real-IO acceptance.

## What is finished

- Private resident-scoped typed cyclic graph, UUID integrity, idempotent writes,
  need/person hubs, dormancy, constitutional protection and mechanical decay.
- Actual semantic embeddings and bounded recall; preview never reinforces,
  selected use commits once, no automatic Hebbian edge creation.
- Opt-in unsought surfacing in both runtime prompt paths, with a hard fail-open
  subprocess budget. No source bodies or inferred room permissions.
- Deliberate export-backed erasure: signed fresh acknowledgement, exact identity,
  constitutional acknowledgement, seven-day cancellable grace, frozen mutation,
  held deletion if the acknowledged graph changes, and anti-resurrection marker.
- Real encrypted paired graph/filesystem backup and restore, archive integrity
  check, transactional preflight validation, suspended failure handling, house API
  and trigger credential rotation, and restored indexing.
- Test-only local backup transport retains namespace/ownership guards and never
  accesses cloud credentials. Production transport remains the existing restic
  path, now using the same tested snapshot/restore orchestration.

## Local evidence

| Check | Result | Checkout-local log |
| --- | --- | --- |
| Full Rails | 2,585 tests, 12,351 assertions, zero failures/errors/skips | `log/mnemodyne-completion-rails-final.log` |
| Full browser | 17/17, no retry this turn | `log/mnemodyne-completion-browser.log` |
| Actual image + HTTP + inference + encrypted restore + erasure | 1 test, 34 assertions, zero failures/errors/skips | `log/mnemodyne-local-smoke-final.log` |
| Normal complete runtime build | Successful, not a debug overlay | `log/mnemodyne-runtime-build-final.log` |
| Private inference image build | Successful | `log/mnemodyne-embedding-image-final.log` |
| Changed Ruby lint | 32 files clean, temporary parser target 3.4 | `log/mnemodyne-completion-rubocop-final.log` |

Both local images are Linux **arm64**; production is amd64 and its normal release
build still has to produce/publish the deployment artifacts. No production build
or production behavior is claimed by the local smoke.

- Runtime `souls-house-agent-runtime:local-2`:
  `sha256:b09be7fde24e598c93a62b279ab692904091654eb6753ffbdfc377808c006c36`
- Embeddings `souls-house-mnemodyne-embeddings:local-2`:
  `sha256:8eed1ac81bb4007edd0b4efb11b80f98c7ff90f2e7f3685a3b30cf175c1349f4`

The runtime build exposed an upstream Chaos Linux compilation error at
`131b7275424db7f9531cb9934a6e74d2234c36cf`. The included minimal patch guards
destructuring of a macOS-only field; it does not weaken sandbox enforcement.
Review/remove it when upstream fixes that binding.

Stock RuboCop was run and fails on the repository's existing Ruby 4.0 parser
incompatibility. No lint rule was weakened. The frontend format check still
reports the same eight untouched files (listed in its log). The pre-existing
`app/frontend/routes/index.d.ts` blank line was not included in this change.
Python compilation passes. An earlier milestone had an intermittent browser
pagination failure; it is documented in the plan, not claimed fixed here.

## Review these deliberate contracts

- Seven days is an implemented, reviewable erasure grace default, not a missing
  policy branch. Erasure does **not** erase canonical files, exported copies or
  retained encrypted backups. Database disaster recovery must preserve erasure
  markers; operators retain privileged access.
- Exact cosine is capped at 5,000 eligible nodes / 20,000 edges. The bundled
  English model truncates at 512 tokens. Scaling and multilingual replacement
  require a new measured/profiled version, not silent changes to this profile.
- Automatic disclosure is explicit all-conversation eligibility per opted-in node,
  not an inferred participant/room policy. Vault enablement does not seed memory.
- Local verification intentionally does not invoke a paid model, deliver real
  messages or use production credentials. Fresh/resumed prompt assembly is tested
  through the actual runtime shim, without claiming a real resident trial.

Next step is Lume's code review, then an explicitly authorized operator release
using the deployment runbook. No further pilot implementation stage is required.
