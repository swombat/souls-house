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
