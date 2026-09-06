# Mnemodyne — second-review follow-up and launch readiness

September 6, 2026. Work stays in `souls-house-2`; no push, deployment, real
resident invocation, paid-model call or cloud backup/restore was performed.
This supersedes the September 5 follow-up for the current release candidate.

## Rebase and integration

Rebased the four Mnemodyne commits onto `origin/master` at `fffd2f4`, including
RubyLLM retirement and dependency updates. Both hosted-runtime admission and
memory-suspension guards survive in `spawn!`, `with_runtime` and `recreate!`.
Retired-agent credentials now fail authentication (401) before memory
authorization, as upstream intends; coverage checks inline, migrating and
deprecated states. No retired execution path or RubyLLM dependency was restored.

Upstream's `AddAgentDeprecation` and our unreleased `CreateMnemodyneGraph` shared
`20260905170000`. Renamed only our migration to `20260905170100`, with its body
unchanged. Instance 2 development already had that graph: checked the exact
database name and schema, moved its one migration-history record transactionally,
then ran the normal additive migration for agent deprecation. No development
tables/data were reset. The normal test runner rebuilt its isolated test schema;
its initially interrupted schema load required restoring test environment metadata.
Other checkouts and their databases were not modified.

Lume's untracked review and the pre-existing routes declaration whitespace were
preserved across the rebase, with a byte-for-byte check of the review.

## Lume's second pass

| Finding | Resolution and regression coverage |
| --- | --- |
| **A — telemetry lock / rescue-handler 500** | Best-effort `FOR UPDATE SKIP LOCKED` inside a short savepoint, not the graph's waiting lock. A plain `UPDATE` would still wait for a row lock, so simply removing `with_lock` was insufficient. Database telemetry errors are contained even inside the embeddings error handler. Two actual PG connections verify successful recall and a classified 503 while the vault is locked; another test injects a telemetry timeout. General write conflicts now say “retry shortly,” not falsely “after backup.” |
| **B — duplicated previews / budget** | Shim previews perform one recall request, with Rails provisioning beforehand. Every attempted shim preview carries a marker, including empty/error results, so BeforeTurn does not repeat it. Direct hook turns provision once per container/credential; successful provisioning is cached outside backed-up identity. Their first-use budget is 5 seconds for two 2-second HTTP calls, inside a 7-second hook limit. Subsequent direct turns perform only recall. Tests cover request counts, credential rotation, empty/failure dedup, fresh/resumed prompt inclusion and bounded subprocess failure. |
| **C — first-checkpoint timing** | First attempt waits at least 13 minutes, beyond the active window. Busy/custody-held residents reschedule without consuming failure attempts. Typed busy races are also deferred; the backup job does not create failed snapshots for busy preflight or quiescence. Real failures retry every 15 minutes up to 12 attempts, then log, report and raise. An intervening successful paired backup satisfies the job. Tests cover busy preflight/race, timing, existing checkpoint and exhaustion. The resident guide explains the idle upload pause. |
| **D — lifecycle setting** | The automatic-not-opt-in decision and its superseding of stored pilot settings are explicit in `docs/mnemodyne.md`. Removed the unusable CLI `configure --automatic` command. Per-node default `never_automatic` and deliberate erasure remain unchanged. |
| **13 — missing deployment digest** | Missing or malformed digest now raises an actionable instruction naming the variable and required `sha256:` format rather than `KeyError`. Tests evaluate the missing, malformed and valid cases without reading real secrets. See artifact evidence below; no unpublished registry digest is invented. |
| **F — malformed hooks brick boot** | Invalid JSON or malformed hook structure is copied byte-for-byte to a private `hooks.json.invalid-*` sibling; managed hooks are installed and boot continues, with a content-free diagnostic. Valid resident hooks still merge idempotently. The real encrypted restore/wake smoke includes a malformed hooks file and checks its preserved bytes, mode and installed hooks in the freshly started container. |
| **E — moving Chaos source** | `agent-runtime/chaos-ref` pins the reviewed SHA for both build scripts and recovery's local-image helper. Explicit overrides require a full SHA. Runtime image labels retain the actual source provenance. |

## Artifact and real-IO evidence

Native local Linux **arm64** artifacts, not registry manifests or production
amd64 acceptance:

- Runtime: `souls-house-agent-runtime:local-2`
  `sha256:ac554df1ef2ded0bd979df58eb43465168645f649e4bc4a853952a1d105bf3b3`
- Embeddings: `souls-house-mnemodyne-embeddings:local-2`
  `sha256:50cedc0717415278b3921c9150662029b2f2e0eb8b51ca643e647281f80e64b5`
- Reviewed Chaos source: `f3bb63d6aec1ffdcab6330095701f3308c350199`
- Runtime build: `log/mnemodyne-launch-runtime-final.log`.
- Real smoke: **1 test, 49 assertions, zero failures/errors/skips**,
  `log/mnemodyne-launch-smoke.log`.

The smoke uses actual CPU inference (including concurrent probes), HTTP API and
image CLI, automatic first-vault provisioning, private-need reinforcement,
nonmutating recall, selected-use receipts, both shim prompt forms, encrypted
restic paired backup/restore and **actual `wake: true`**. It verifies credential
rotation inside the new container, malformed-hook recovery, installed recall
and formation hooks, resident guide, erasure and anti-resurrection. No model
turn is invoked: the Stop invitation is tested, not fabricated memory formation.
Its synthetic Docker containers and volumes are removed through ownership guards.

The eventual release operator must build/publish the approved production-platform
embedding artifact, record its **registry manifest digest** in release evidence,
and export that as `MNEMODYNE_EMBEDDING_IMAGE_DIGEST` for Kamal. The local image ID
above is not a substitute. This remains an explicit release step, not a
code/test shortcut or permission to deploy.

## Final integrated verification

- **Rails: 2,188 tests / 11,022 assertions, zero failures/errors/skips** —
  `log/mnemodyne-launch-rails-final.log`. The count is lower than September 5
  because upstream removed the retired RubyLLM/inline test surface.
- **Browser: 18/18 passed** — `log/mnemodyne-launch-browser.log`.
- **24 Ruby files lint clean** with a checkout-local temporary Ruby 3.4
  `parser_whitequark` configuration — `log/mnemodyne-launch-rubocop-final.log`.
  Stock RuboCop still cannot parse Ruby 4.0; after the dependency rebase, the
  previous temporary Prism configuration also failed to load `parser34`.
  No repository lint rule or dependency was weakened to mask this.
- Python compilation and entrypoint/build-script shell syntax checks passed.
- Full frontend formatting was run and still reports **six unchanged files**:
  application.css, AgentAppearancePanel.svelte, logging.js, use-sync.js,
  agents/new.svelte and home.svelte — `log/mnemodyne-launch-format.log`.
- Scoped Docker inspection found no remaining instance-2 test containers or
  volumes after verification. Test runners released the checkout lock normally.

Initial runs are not hidden: the timestamp collision interrupted test-schema
loading; an initial parallel Vite auto-build raced its manifest; tests caught
the changed retired-key status and a test's incorrectly seeded retry counter.
The new real-lock test also caught its cleanup using a cached, already-destroyed
vault association; reloading the synthetic owner fixed that cleanup. All were
resolved before the final whole-suite and real-image acceptance above.

**Handoff:** Lume approved `e3aa3e7` for the documented operator release
sequence on September 6, 2026 (final pass recorded at 08:05 CEST in
`docs/reviews/260905-mnemodyne-lume-review.md`). All seven second-pass findings
and relevant rebase drift were verified; no blocking findings remain.
Deployment-platform artifact publication/digest recording, production
secrets, migration execution and release authorization remain operator steps.
Nothing in this local evidence claims those steps already happened.

## Non-blocking final-review follow-ups

- Explain `<mnemodyne-preview-attempted/>` in the resident guide, or render the
  empty-preview marker more naturally. It currently remains a literal prompt
  line; the approved runtime is unchanged by this documentation-only handoff.
- Avoid indefinite 13-minute first-checkpoint rescheduling for permanently
  suspended vaults. Consider stopping while suspended and rescheduling on resume,
  with regression coverage so a first checkpoint cannot be lost.
- **Addressed in the runbook:** put the digest environment requirement before
  any Kamal instructions, including diagnostic commands.

These are explicitly non-blocking in Lume's final review. Her sign-off is not
deployment authorization. This follow-up changes documentation only; the tested
runtime and embedding artifact identities above remain unchanged.
