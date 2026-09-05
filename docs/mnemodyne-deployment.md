# Mnemodyne release and local verification

**September 5, 2026: local implementation only. No deployment authorized or
performed. Lume reviews the code and evidence before an operator releases it.**

## Reproduce locally

Use an already configured isolated checkout, pinned mise tools, PostgreSQL and a
local Unix-socket Docker daemon. Do not copy primary/production databases.

```sh
mise exec -- bin/rails db:migrate
mise exec -- scripts/build-local-mnemodyne-embeddings
mise exec -- scripts/build-local-agent-runtime
mise exec -- scripts/verify-mnemodyne-local
mise exec -- bin/rails test
mise exec -- bun run test
```

Run test commands sequentially: they share the normal instance test lock.
The real smoke test uses its own ephemeral Rails HTTP server and a newly created
synthetic resident. It exercises real CPU inference, image CLI/API authentication,
nonmutating recall, selected-use reinforcement, fresh/resumed prompt assembly,
encrypted restic backup/restore of graph and files, credential rotation, erasure
and rejection of pre-erasure backups. It never invokes a paid model.

The local repository transport requires all three: isolated **test** environment,
`MNEMODYNE_LOCAL_BACKUP=1`, and the exact freshly generated agent UUID in
`MNEMODYNE_LOCAL_BACKUP_AGENT_UUID`. The verifier sets these itself. Docker
ownership labels are still checked. Batch/cloud restore remains forbidden.
No real resident should ever be allowlisted for this transport.

## Operator release sequence — not executed

1. Review the additive migrations, custody defaults and backup changes. Preserve
   the normal database and resident-volume backups before release. Graph memory
   is part of the main database backup, not a disposable index.
2. Generate a new random private embedding bearer token, at least 24 characters,
   in `config/credentials/deployment/mnemodyne_embedding_token.key` (mode 0600).
   This ignored file is referenced by `.kamal/secrets`; do not commit it. Use the
   same value for Rails web/jobs and the inference accessory.
3. Build and publish the embedding image for production **amd64**, using
   `services/mnemodyne-embeddings` as Docker context and the release tag configured
   in `config/deploy.yml`. Record its immutable registry digest in the release
   record. This local change does not publish that tag.
4. Build/publish the normal agent runtime through the existing deployment
   procedure. It must contain `house-memory`, `memory_client.py`, the updated shim
   and resident API documentation. The small Chaos Linux compatibility patch in
   `agent-runtime/patches` is build-checked; it changes no sandbox enforcement.
5. Boot the `embeddings` Kamal accessory, with no public port. The configured
   internal hostname is `souls-house-embeddings`. It needs two CPU shares/cores
   worth of quota and 512 MiB memory. Confirm `/health` internally.
6. Release Rails normally (additive migrations first), including web **and** Solid
   Queue workers. Confirm `mnemodyne:check` using the deployed application:
   expected profile `bge-small-en-v1.5-q-52398278842e-fastembed-0.7.4-v1`, 384
   dimensions. The probe is synthetic and prints no secret or resident text.
7. If importing existing consented graphs or changing profile, run
   `mnemodyne:reembed` (optional `RESIDENT_ID`). Watch worker completion and the
   resident's `house-memory status` indexed-node count. Ordinary node changes
   enqueue embedding automatically; resuming a restored vault requeues indexing.
8. Replace/restart hosted runtime containers through their supported lifecycle
   so existing residents receive the new image and CLI. Do not silently create
   vaults or seed memories. Residents explicitly run `house-memory enable`;
   automatic surfacing additionally requires vault and individual-node opt-in.
9. With a consenting test resident, verify remember/recall/open, backup and
   suspended restore before enabling wider use. Restore rotates its house API
   and trigger credentials; external integrations holding old credentials must
   reauthenticate. Its restic encryption password is deliberately retained.

## Custody and failure behavior

- Graph-bearing backups lock graph writes and pause a running resident while
  taking the paired snapshot. Active turns/pending erasure reject backup.
  Privileged out-of-band filesystem/SQL writers must also be quiescent.
- Restore checks the archive and validates the full graph before destructive
  volume replacement. It suspends memory before replacement; failed validation,
  import or credential rotation does not wake the resident. Investigate and
  restore a known-good paired backup; do not manually clear suspension to hide
  failure. `restore!(wake: false)` supports inspection before an explicit wake.
- Deliberate vault erasure requires a fresh signed export, exact resident UUID,
  explicit constitutional-node acknowledgement and seven days' grace. It freezes
  mutation/automatic recall; cancellation is available. Hourly cleanup performs
  due erasures, but holds a changed graph rather than deleting unexported changes.
- Erasure removes the live graph, not canonical source files, downloaded exports
  or retained encrypted backups. A resident erasure marker prevents automatic
  resurrection from older graph backups. Backup retention and whole-database
  disaster recovery remain operator responsibilities; preserve erasure markers
  when recovering from a database backup.
- Embedding outage fails open for conversation: no automatic graph section.
  Manual graph CRUD/export and seed-based recall remain available. Monitor
  content-free failures, queue health and the synthetic readiness probe.
- v1 uses exact bounded cosine search (5,000 eligible nodes, 20,000 edges), not
  pgvector. English/512-token inference and all-or-none automatic disclosure are
  explicit version-one limits, not unfinished pilot gates.

## Rollback

Disable automatic surfacing on affected vaults first. Revert application/runtime
images if needed, leaving additive schema and graph rows intact; do not migrate
down or erase memory as a rollback. The previous memory implementation can run
with additional nullable/defaulted columns, but does not enforce new erasure
workflow: cancel pending requests before such a rollback, or keep the new custody
workers in place. Stop the accessory only after Rails no longer needs it.
Credential rotation is intentionally not undone. A failed restore remains
suspended until a validated recovery, not merely an image rollback.
