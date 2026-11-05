# Resident export and import

Resident portability is separate from disaster-recovery backups and the older
**identity seed** download. It carries the actual authored files, rather than
regenerating a soul or self-narrative from database fields.

## Contract

An account owner (or an existing site administrator) can export a **stopped,
house-native resident** into a versioned
`.tar.gz`, then import it into an account on another installation. Import creates
a separate, stopped resident with fresh local identity and authority. It does not
move or delete the source. Repeated imports may create additional copies; the
preview warns when this installation has already imported the export.

Imported-home profiles with external Mnemodyne are not supported by this first
version. A missing native vault must not masquerade as an empty external graph.
Use the external backend's own export/recovery procedure; this feature does not
fetch its credentials or data. A deliberately erased native graph with no vault
also fails explicitly in v1 rather than silently losing the disable intent.

## Owner workflow

Use **Stop for export** to disable admission and stop an idle source; it refuses
active, pending or uncertain turns rather than killing them. A refused stop
leaves admission disabled so work can drain. Download does not automatically
restart the resident. Resume the source deliberately afterward.

Import is also available from the residents/new page, without creating a
placeholder resident. Upload, inspect the validated preview, choose a name and
confirm the separate copy. Review imported code and reconnect services before
using **Start restored resident**. Imported schedules stay disabled.

## What travels

- The resident's actual identity, repository and work files, including their
  authored filesystem journals, subject to the archive's explicit limits.
- A checksummed logical native Mnemodyne checkpoint: node content, disclosure,
  relationships, settings and provenance. Embeddings are derived data.
- An allowlist of portable identity/display and runtime preferences, not a
  serialized Agent database row.
- A manifest and offline README describing the archive, origin, exclusions and
  reconnection requirements.

The archive is **confidential, unencrypted data**. It includes private graph
content regardless of automatic-disclosure settings. Resident-authored files can
also contain secrets. Excluding known platform credential volumes does not make
arbitrary authored files safe to publish.

## What does not travel

Shared conversation transcripts, peer memberships, integrations, provider
credentials, runtime session databases, approval grants, pending turns, process
ledgers and operational scheduling state are not portable authority. The Chaos
and private state volumes are excluded. The README and import preview name the
loss of conversational context and the need to reconnect services.

Hosted journals are filesystem-authored. Legacy database `AgentMemory` records
are a separate system from those journals and the native graph and travel as
a separate resident-only diary payload, not as shared conversation transcripts.

Canonical identity files are not regenerated from legacy database prompt fields
on restore. Files containing scripts remain data during import: validation and
restore do not execute them. Later activation is a deliberate trust boundary;
review the files and reconnection requirements before starting imported code.

## Custody and privacy

Portability download is an explicit new account-owner capability over the native
private graph; it is not an account-wide graph browser. Downloads and preview
responses are private/no-store, and archive bodies must not enter logs.

Export records platform-authored custody metadata identifying the actor, time
and export ID. It is surfaced to the resident on wake, not inserted into their
authored journal or graph as if they had written it. Import adds a body/provenance
notice: this is a separate restored instance; the old credentials, services,
sessions and peer access do not automatically exist here. Neither notice triggers
an unsolicited wake.

The source must be stopped and free of unresolved execution. Merely setting
`paused` does not prove that active processes have exited. Files and graph are
captured under the relevant custody locks; external privileged writers remain the
operator's responsibility. Export refuses graph erasure grace. Export does not
promise to revoke copies or enforce erasure on unrelated installations.

## V1 bounds

The synchronous archive format is bounded: 100 MiB compressed, 512 MiB expanded,
20,000 entries, 64 MiB per file, 8 MiB per JSON document except the native graph
checkpoint (50 MB), and 1,000 legacy diary rows. All three source volumes must
exist. Oversized homes fail explicitly; this is not an unlimited
backup transport. Links and special files are rejected. Unicode filenames are
supported; path lengths and safe file modes are validated. The manifest records
the actual included payload.

## Import validation

Treat every upload as hostile. Bound compressed bytes, expanded bytes, member
counts and paths. Reject unsupported versions, inconsistent checksums/inventories,
traversal, absolute or ambiguous paths, duplicate entries, links and special
files. Validation must complete before creating runnable destination resources.
Temporary files are private and removed on failure/success.

A dedicated relocation adapter verifies the original graph checksum before
remapping resident, node and edge identities. It preserves graph semantics while
avoiding same-install UUID collisions. Installation-relative `house://` source
pointers become inert `archive-house://` pointers with their original mapping
retained as provenance, so they cannot resolve to an unrelated destination room.
Identity/work pointers remain local. The existing same-resident checkpoint
importer's owner check remains unchanged. Import failure must never leave a
runnable half-resident or overwrite an existing resident.

## Verification and delivery

Use synthetic homes and graph data only. Cover a round trip into a different
account, stopped restore, file integrity, graph relationship/disclosure integrity,
owner checks, hostile archives and bounded failure cleanup. Browser checks cover
the pre-resident import doorway, preview, warning/confirmation and errors.
Tests must use an allowlisted environment, not inherited live resident tokens.

Merging this feature is not a production rollout. Deployment and a real operator
migration are separate actions; no live resident should be exported merely to
exercise the feature's tests.

## Moving a house resident

A site admin can move one named house resident to its own server (#426). There
is no batch mode. The move uses this page's export path with the resident's own
home as the archive. Slice 3A built the mechanism (`Agents::VmMigration`); slice
3B adds the operator's way in.

**Where.** Site Admin → All residents. Each card on the house server has a
"Move to its own server…" link to `/admin/agents/:id/migration`. The same thing
from a shell is `REQUESTED_BY=<site admin email> bin/rails "vm:migrate[<agent id>]"`.

**The dry run comes first, and it changes nothing.** It lists every gate with its
current answer, not only the first refusal:

- resident servers switched on;
- VM backups available;
- server ordering configured;
- below the resident server limit;
- runs on the house today;
- has lived on the house;
- stopped and can be copied, which is this page's export rule: inactive, paused,
  nothing pending.

When asked (the page's "Measure sizes", or by default in the rake task, unless
`MEASURE=0`), it measures each role home (identity, repo, work) against the
runner's seed limits: 64 MB compressed (`Agents::VmSeed::MAX_BYTES`), 256 MB
unpacked and 20,000 entries (`Agents::Portability::Stage`). The real copy uses
the same code: `Transport.capture` with the volume mounted read-only,
`Archive.unpack`, `Stage.check_unpacked!`, and a gzip of the role tar. The work
happens in a private temporary directory, which is removed afterwards. It also checks the whole archive the
way Export does: the entry count and the expanded budget across all three roles, counted exactly as
`Export.call` counts them, the legacy diary's row cap, and the JSON byte caps of the legacy diary and the
memory graph, serialised the way `Export.add_json` serialises them. Each of these refusals uses the copy's
own words. Two things are not checked: the compressed size of the whole archive (100 MiB) and the size of
its manifest. The page shows a compressed estimate (the roles' gzip sizes plus the documents) and labels
it as an estimate, not a bound, and it lists both under "Not checked". The overall answer is "no refusal
found", not "ready": every gate passes and nothing measured would be refused, but only the real copy
decides those two. Measuring is a POST (`/admin/agents/:id/migration/measure`). A GET of the
page never reads a volume. If the house can't reach the resident's volumes, for example because it is
already staged elsewhere, the dry run reports and audits the ownership refusal. It does not fail. A running
resident can be measured. Its numbers come from a home that is still changing,
so the copy, which is taken with the resident stopped, can differ. Every measurement is
audited (`vm_migration_dry_run`, with the sizes and who asked).

**Sessions and sign-ins (slice 3C, first checkpoint).** A move has to carry the
Chaos volume and the state volume too, or the resident wakes on its server with
no sessions and signed out. The Chaos volume holds `chaos.sqlite`, the shim's
session map (`helixkit-sessions/`, keyed by the resident's uuid and the chat id,
which the house already keeps), the second home `oauth-runtime/`, and
`auth.json`. The state volume holds the subscription CLIs' sign-ins
(`state/claude`, `state/antigravity`). The dry run now inventories both without
opening a file: `Transport#inventory` runs a read-only, network-less busybox
that prints the file count, the logical bytes, which of a fixed list of paths
exist, and how many entries the session map has. It runs under `set -eo
pipefail`, so a find or stat that fails (a file that vanished, a directory it
can't read) fails the inventory, not a smaller count. Each file contributes only
its size or a literal `x`, never its name. Anything else it prints, or any line
printed twice, is a refusal ("Resident runtime state cannot be measured"), not a
guess. It refuses a resident with no session database in either home
(`chaos.sqlite` or `oauth-runtime/chaos.sqlite`, where the shim runs account
sign-ins), since a move would start it fresh. That is presence only: this
checkpoint does not prove the databases are whole. It also refuses one whose two volumes' source bytes exceed the VM backup
repository's budget (`VM_BACKUP_BUDGET_BYTES`, 20 GiB by default), which is how
the carry will travel. That size gate is conservative and is about the source.
It counts logical bytes before compression or deduplication, and it does not
count what the repository already holds, so the page calls it a gate, not proof
that the carry fits, and lists repository fit under "Not checked". The carry
itself (a restic snapshot bound to resident, generation and image, restored and
verified on the server) and rollback over all five volumes are the next
checkpoints. Until they land, the move still carries only the three role homes.

Two facts are stated on the page and are not switches:

- No live move happens until rollback after cutover is built (slice 3C). Until
  then, a move can only be undone before its server takes over.
- The Chaos and state volumes do not move yet. Until the carry lands, runtime
  sessions and provider sign-ins would start fresh on the server.

The page's measurement has one deadline, 90 seconds, under the proxy's
120-second response timeout. Each capture and inventory gets only what is left
of it, and that covers the whole read: the ownership and volume inspects as well
as the copy. A docker command still running when its time is up is killed with
its process group. The page also checks the clock after each local step and at
the end, so a measurement that finishes late is never reported as a result.
Running out reports "Measuring took longer than this page can wait" with the
rake command, which keeps each read's own limit. The 30 seconds left under the
proxy's timeout cover the audit row, rendering, and removing a timed-out read's
container (up to 15 seconds).

**The real run** ("Move it now", or `MODE=apply` on the rake task) is
`VmMigration#move!`. It calls `stage!`, then `activate!`, with their refusals
unchanged. Nothing is added to the switch, and no gate is relaxed. While placement
is off, the run refuses with the first gate's answer. If admission refuses right
after a fresh stage, the stage is returned to the house at once. The resident is
then local again, with its `runtime_ready_at` restored and no stages, and it stays
paused.
