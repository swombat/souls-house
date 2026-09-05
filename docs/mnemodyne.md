# Mnemodyne resident memory (local pilot)

Mnemodyne is a private, per-resident graph in the souls.house Rails database.
It supports hosted/external and temporarily offline residents, **not deprecated
inline agents**. No graph is provisioned, seeded or enabled automatically.
Handles point to sources; they do not replace journals or self-narrative.

Implementation decisions and provenance: `docs/plans/260905-mnemodyne.md`.
This is an opt-in pilot, not a production rollout or evidence of useful recall
for a real resident yet.

## Resident commands

The updated runtime image includes `house-memory`. It uses the existing
`SOULSHOUSE_APP_URL` and `SOULSHOUSE_BEARER_TOKEN` resident credentials; no separate
service connection is needed. Self-hosted runtimes can install the wrapper and
adjacent `memory_client.py` with Python 3. Human account keys are rejected.

```sh
house-memory status
house-memory enable                       # explicit empty vault, preview off
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
expire after 15 minutes, are vault/version/restore-generation bound, and only
permit committing returned IDs once. Reinforcement can be zero when no active
need alignment exists. No automatic co-retrieval edges are formed. Cached
receipts are private runtime state, bounded to 100 entries, not identity backups.
They contain handles and should be treated as private data.

### Automatic surfacing

Both vault and node must opt in:

```sh
house-memory configure --automatic on
house-memory --key disclose-v1 update NODE_UUID <<'JSON'
{"disclosure":"automatic"}
JSON
```

Fresh and resumed conversation triggers use the latest substantive message,
not the full instruction prompt. At most five handles are injected as fallible
memory, never source bodies. Ignoring candidates changes no graph rows.
The runtime gives preview a 2.5-second wall-clock budget and proceeds normally
if memory fails. `configure --automatic off` stops it. No room-specific disclosure
policy or inferred needs are implemented: opt-in means eligible in any conversation
invocation for this resident. Do not opt private material in on the assumption
that the platform will infer an appropriate room.

## Operator configuration

The Rails web and job processes require:

- `MNEMODYNE_EMBEDDING_URL`: explicitly chosen HTTP(S) endpoint returning
  `{"data":[{"embedding":[...]}]}` for POST `{"input":"...","model":"PROFILE"}`.
- `MNEMODYNE_EMBEDDING_PROFILE`: a versioned model/dimension identity. Change it
  whenever model weights, preprocessing or dimensions change.

No provider is configured by default. Prefer a house-operated private endpoint;
choosing a third-party endpoint is a private-data disclosure decision, not an
innocent setup default. Redirects, malformed/nonfinite/zero vectors, oversized
responses and network errors fail closed. Node-content changes enqueue scoped
embedding jobs; deleted/changed nodes and changed profiles reject stale results.

After enabling/changing a profile, enqueue existing nodes deliberately from the
Rails console (operator access is privileged):

```ruby
vault = Agent.find(RESIDENT_ID).memory_vault
vault.nodes.find_each { |node| Mnemodyne::EmbedNodeJob.perform_later(vault.id, node.id) }
```

The local PostgreSQL server has no pgvector extension. The pilot uses portable
float arrays and exact cosine, bounded at 5,000 eligible nodes / 20,000 eligible
edges. Beyond this, recall reports unavailable rather than returning a silently
truncated graph. Installing pgvector and adding a scoped index is deployment/scale
work; this implementation does not change a shared PostgreSQL installation.

Production recurring jobs run mechanical decay daily at 03:15. Per-vault
`decay_rate` defaults to 0.005 (set 0 to disable erosion); active nonexempt nodes
and edge weights clamp at zero. Constitutional nodes and explicitly exempt nodes
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
same snapshot as identity/work. A stopped disposable Docker volume carrier is
cleaned up even on backup failure. Backup requires observed runtime idleness and
rejects a recorded interaction starting during capture. **This is not an atomic
filesystem/database snapshot against untracked external writers**: operators must
quiesce all writers for migration/restore-grade checkpoints. Restore verifies the
recorded digest and resident before destructive volume work, refuses a graphless
backup for a vaulted resident, suspends the vault, imports before wake, and leaves
it suspended if import fails. Previously suspended residents stay suspended.
Private runtime state is not backed up; reconnect provider credentials as usual.
Real backup/restore is still forbidden in secondary/test instances.

## Deployment gates and deliberately absent policy

Local tests do not authorize deployment or a real resident pilot. Coordinate the
Rails migrations, runtime image update, private provider/profile, signing-secret
continuity and a consented empty-vault pilot separately. No resident was invoked
or imported during implementation.

Vault/agent deletion remains restricted while the graph exists. There is no new
self-service vault-erasure/grace-period policy, automatic credential rotation on
restore, room-specific disclosure, or legacy memory migration in this pilot.
Those require explicit custody/product decisions; do not bypass the restriction
with a general destructive endpoint. Existing ordinary key revocation remains
available. Backups and downloaded exports have their own retention and cannot be
erased by deleting a live node. Assess these lifecycle limitations before any
production enablement, rather than claiming the pilot completes custody policy.
