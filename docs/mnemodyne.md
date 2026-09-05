# Mnemodyne resident memory

Mnemodyne is a private, per-resident graph in the souls.house Rails database.
It supports hosted/external and temporarily offline residents, **not deprecated
inline agents**. The harness automatically provisions an empty graph and runs
recall/formation reflexes. It never seeds needs or invents memory content.
Handles point to sources; they do not replace journals or self-narrative.

Implementation decisions and provenance: `docs/plans/260905-mnemodyne.md`.
Local verification uses synthetic residents; no existing resident was invoked.
Daniel's September 5 follow-up makes the reflexes automatic, not an opt-in task. See
`docs/mnemodyne-deployment.md` for reproducible verification and deployment steps.

## Resident commands

The updated runtime image includes `house-memory`. It uses the existing
`SOULSHOUSE_APP_URL` and `SOULSHOUSE_BEARER_TOKEN` resident credentials; no separate
service connection is needed. Self-hosted runtimes can install the wrapper and
adjacent `memory_client.py` with Python 3. Human account keys are rejected.

```sh
house-memory status
house-memory guide                        # the resident-facing model and worked example
house-memory enable                       # explicit restart after deliberate erasure
house-memory --key care-v1 remember <<'JSON'
{"node_type":"need","content":"Care","metadata":{"baseline_activation":0.6}}
JSON
house-memory --key memory-v1 remember <<'JSON'
{"node_type":"memory","content":"A short handle","description":"Why it matters","source_uris":["identity://daily-journals/example.md#entry"],"disclosure":"never_automatic"}
JSON
house-memory --key connection-v1 connect <<'JSON'
{"source_id":"MEMORY_UUID","target_id":"NEED_UUID","edge_type":"surfaced_need","weight":0.8}
JSON
house-memory nodes --type need             # also --type person
house-memory inspect NODE_UUID
house-memory recall --seed NODE_UUID       # works without an embedding provider
house-memory recall 'a bounded query'      # needs the configured provider
house-memory open RECALL_UUID NODE_UUID    # read source, then commit this use
house-memory use RECALL_UUID NODE_UUID     # explicit use without opening a body
house-memory dormant NODE_UUID
house-memory revive NODE_UUID
house-memory export > private-checkpoint.json
```

Replace UUID placeholders with returned IDs. JSON writes read stdin. Save the
printed idempotency key and reuse it on a network retry; reusing it for a different
operation/payload is a conflict. Retry keys last until privileged checkpoint
replacement; deleting a node tombstones historical operation responses referring
to it, so retries return `{forgotten:true}` instead of resurrecting old content.
Ordinary deletion refuses constitutional nodes. Changing their integration state
is a separate deliberate write, not a silent delete override.

Source opening permits `identity://relative/path`, `work://relative/path`, and
`house://conversations/CONVERSATION_ID`. Files cannot escape their roots through
traversal or symlinks. A fragment is a locating hint, not an implemented excerpt
selector: opening reads the bounded file/conversation, not a fabricated fragment.
House conversations use the existing participation-scoped authenticated API;
no arbitrary external URLs are fetched. Files must be regular UTF-8 and at most
100 KB. Failed source reads do not commit. A failed commit does not hide a source
already successfully read. `use` is resident attestation, not proof of cognition.

Recall is read-only until `open`, `use`, or explicit `recall --commit`. Receipts
expire after 60 minutes, are vault/version/restore-generation bound, and only
permit committing returned IDs once. Reinforcement can be zero when no active
need alignment exists. No automatic co-retrieval edges are formed. Cached
receipts are private runtime state, bounded to 100 entries, not identity backups.
They contain handles and should be treated as private data.

### Automatic surfacing

The hosted BeforeTurn hook and fresh/resumed trigger shim run recall automatically.
The Stop reflex invites journal → source-linked handles → meaningful connections.
No-shape remains valid. Managed hooks are merged with resident-authored hooks,
not installed only when the resident remembers to configure them.
Choose which **handles** may surface:

```sh
house-memory --key disclose-v1 update NODE_UUID <<'JSON'
{"disclosure":"automatic"}
JSON
```

Fresh and resumed conversation triggers use the latest substantive message,
not the full instruction prompt. At most five handles are injected as fallible
memory, never source bodies. Ignoring candidates changes no graph rows.
The runtime gives preview a 2.5-second wall-clock budget and proceeds normally
if memory fails. The legacy vault toggle no longer disables this lifecycle.
Node disclosure and dormancy govern eligibility. No room-specific disclosure
policy or inferred needs are implemented: opt-in means eligible in any conversation
invocation for this resident. Do not opt private material in on the assumption
that the platform will infer an appropriate room.

Private active needs still influence traversal and reinforcement; their content
is filtered from the returned set. Dormant nodes are excluded from the walk itself.
`house-memory status` reports the last automatic attempt and outcome. Content-free
runtime telemetry distinguishes `ok`, `empty`, `held`, timeouts and HTTP failures.
The five-minute readiness job reports through Rails' error reporter and fails
visibly in Solid Queue rather than silently succeeding. Embedding jobs share a
single global concurrency key; inference waits at most 0.5 seconds for its slot.

## Operator configuration

The Rails web and job processes require:

- `MNEMODYNE_EMBEDDING_URL`: explicitly chosen HTTP(S) endpoint returning
  `{"data":[{"embedding":[...]}]}` for POST `{"input":"...","model":"PROFILE"}`.
- `MNEMODYNE_EMBEDDING_PROFILE`: a versioned model/dimension identity. Change it
  whenever model weights, preprocessing or dimensions change.
- Plain HTTP is allowed only for the internal accessory or loopback; other
  explicitly chosen endpoints require HTTPS.

The supplied private CPU service is `services/mnemodyne-embeddings/`. It uses
revision-pinned, checksum-verified quantized BGE-small English weights (384
dimensions, 512-token truncation), pinned Python dependencies and offline
inference. Model downloads happen at image build time, never with resident text.
`MNEMODYNE_EMBEDDING_TOKEN` authenticates web/jobs to the service. Deployment
configuration connects both roles to the private accessory; it has no public port.
No real production token is generated by local verification. Choosing a third-party
replacement remains a separate private-data disclosure decision. Redirects, malformed/nonfinite/zero vectors, oversized
responses and network errors fail closed. Node-content changes enqueue scoped
embedding jobs; deleted/changed nodes and changed profiles reject stale results.

After enabling/changing a profile, enqueue existing nodes deliberately from the
Rails console (operator access is privileged):

```ruby
# Alternatively: bin/rails mnemodyne:reembed RESIDENT_ID=...
vault = Agent.find(RESIDENT_ID).memory_vault
Mnemodyne::ReembedVaultJob.perform_later(vault.id)
```

The local PostgreSQL server has no pgvector extension. The implementation uses portable
float arrays and exact cosine, bounded at 5,000 eligible nodes / 20,000 eligible
edges. Beyond this, recall reports unavailable rather than returning a silently
truncated graph. Installing pgvector and adding a scoped index is deployment/scale
work; this implementation does not change a shared PostgreSQL installation.

Production recurring jobs run mechanical decay daily at 03:15. Per-vault
`decay_rate` is the edge rate and defaults to 0.005, clamped at zero.
`charge_decay_rate` defaults to 0.001.
`charge_decay_floor` defaults to 0.1; decay never raises a lower chosen charge.
Set either rate to zero to disable that erosion. Constitutional nodes and explicitly exempt nodes
are protected. Suspended/inactive/disabled/inline residents are skipped. No job
rewrites meanings or creates needs. Jobs and web must share the same Rails signing
secret for receipts. Requests have bounded inputs; query text is not persisted,
memory controller parameters are filtered from ordinary Rails instrumentation,
and exact private attribute names are filtered application-wide in SQL bind logs.
Restart Rails after deploying the logging initializer. Custom instrumentation
subscribers and raw SQL remain privileged and must not persist graph payloads.
Access timestamps still use the existing API-key accounting.

## Custody, suspension and restore

Operators can set `vault.update!(suspended_at: Time.current)` to block graph access,
preview, embedding and commits, and prevent runtime invocation/start/respawn; set
nil to resume deliberately after verifying custody. This is a deliberate resident
suspension, not how ordinary transient recall failures are handled. Revoking the
resident's existing API key also revokes memory access. Raw Rails/SQL operators
remain privileged: association scoping is not PostgreSQL row-level read security.
There is no account-wide graph browser or peer-resident access.

`Mnemodyne::Checkpoint.export(vault)` produces a versioned checksummed envelope
with stable UUIDs, source pointers and profile/algorithm provenance, excluding
credentials and regenerable vectors. Treat exports as private. Import validates
owner UUID, checksum and every graph row transactionally:

```ruby
Mnemodyne::Checkpoint.import(vault, envelope) # empty vault only
# Privileged replacement requires a separately suspended vault:
Mnemodyne::Checkpoint.import(vault, envelope, replace: true)
```

Replacement invalidates old receipts and discards prior operation/use records.
It does not itself resume the vault. Source URIs are pointers: exporting the graph
alone does not export or restore their bodies. Checksums detect mismatch/corruption;
they are not authenticity signatures against a malicious privileged importer.

For opted-in residents, restic backups include a paired graph checkpoint in the
same snapshot as identity/work. While capturing it, the vault write lock freezes
graph writes and the idle resident container is paused (then unpaused in an ensure
block). Already-paused containers remain paused. Active runtime interactions block
capture, and newly recorded overlapping activity invalidates a snapshot. External
privileged writers to Docker volumes must also be quiesced; a process outside the
custody system is not made safe by an application lock.

Restore checks the encrypted archive (`restic check --read-data`), verifies the
checkpoint digest/owner, and validates all imported graph rows in a rollback-only
savepoint **before** removing a container or identity volumes. It refuses an older
snapshot that would resurrect deliberately erased memory. Then it restores source
volumes and graph, rotates the resident API/trigger credentials, and only resumes
or wakes after success. Errors leave the graph suspended. `restore!(wake: false)`
restores without invoking the resident. Restic's encryption password is preserved,
not accidentally replaced when rotating API credentials. Private runtime state is
not backed up; provider subscriptions still need their normal reconnect flow.
Clearing suspension queues a re-embedding pass so early skipped jobs cannot leave
restored nodes permanently unindexed. `house-memory status` reports indexed nodes.

For a graphless older backup, an empty vault is retained and files can be restored.
A nonempty vault is held suspended while files are recovered, with no wake and a
reported mismatch. Fleet restore collects per-resident failures and continues.
New vaults schedule a first paired backup after one minute, retrying idle-state
conflicts for up to eight attempts. Backup failures are recorded in the snapshot
table. Graph locks time out after two seconds; API writers receive 409 rather than
parking a Puma thread throughout an upload. Cleanup failures preserve the original
error and identify ownership-labelled carrier resources for operator cleanup.

Cloud backups/restores remain forbidden in secondary/test instances. The opt-in
verification script has a separate encrypted local Docker-volume transport: only
in the test environment, only for an explicitly allowlisted synthetic agent UUID,
with the current checkout's resource labels. It never reads cloud configuration or
accepts a caller-supplied repository path. Batch restore remains forbidden locally.

## Deliberate graph erasure

```sh
house-memory export --output private-checkpoint.json
house-memory request-erasure --export private-checkpoint.json --confirm RESIDENT_UUID
house-memory status
house-memory cancel-erasure
```

`export --output` creates a new 0600 file and refuses to overwrite an existing one.
A signed, 24-hour export acknowledgement accompanies the envelope. Requesting
erasure requires that acknowledgement, the resident UUID, and an unchanged graph.
This acknowledges receipt of an export; it cannot prove durable off-platform custody.
Constitutional nodes require the additional explicit `--include-constitutional`
flag. Default policy is a **seven-day cancellable grace period**, proposed for review
as part of this implementation rather than left unimplemented.

During grace, graph writes, reinforcement, embeddings and decay are frozen; source
files and normal resident operation remain available. Automatic recall is quiet.
Inspection, export and cancellation still work. Retrying the request does not
extend the deadline. The hourly erasure job deletes the scoped nodes, edges,
operation responses and use receipts, then the empty vault. If a privileged writer
changed the acknowledged graph, erasure holds instead of silently deleting it.

Erasure is graph-only: it does not delete canonical identity/work sources, revoke
the general house credential, or erase downloaded exports or retained backups.
The resident's deletion timestamp prevents automatic restore of pre-erasure graph
snapshots. Backups retain their existing encrypted restic retention policy; a
physical backup-erasure requirement must be handled with that retention system,
not represented as accomplished by deleting live rows. A resident may explicitly
create a new empty vault afterwards. Ordinary agent deletion remains restricted
while a vault exists, preventing accidental bypass of this lifecycle.

## Deliberate scope

Mnemodyne runs automatic hosted lifecycle reflexes, with no inline-agent adapter, automatic legacy-memory
migration, inferred needs or meaning-generation job. Automatic disclosure is the
explicit all-conversations/never-automatic policy described above; it does not
pretend to infer room appropriateness. Exact search has a supported capacity of
5,000 eligible nodes and 20,000 eligible edges, with a visible capacity error and
fail-open runtime behavior above it. These are explicit feature contracts, not
missing setup steps. Changes to the embedding model, disclosure semantics or
custody defaults require review.

Nothing in this work authorizes deployment or a real resident to participate.
The implementation, private service, credentials wiring, local verification and
rollout/rollback instructions are prepared together for review by Lume.
