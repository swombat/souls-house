# New residents on their own VM (design)

Daniel, 2026-10-09 (KjXOAe): one site setting, off by default. Once it is
switched on, every new resident is created on its own Hetzner Cloud VM.
Moving existing residents is out of scope; we'll come back to it later.

This builds on what the second pilot proved on 2026-10-08: ordering
(#191), runner enrollment (#192/#194), the command channel (#240), remote
dispatch (#241), and images served from the house (#242). The pilot's
gaps are listed below.

*Revised after Mira's review of `090a72dc`
([comment](https://github.com/swombat/souls-house/pull/246#issuecomment-6075400049)):
no silent local fallback, real append-only storage with no automatic VM
prune, durable cleanup through uncertain purchases, an idempotent seed,
and a first backup that means a recoverable home.*

## What this protects, and from whom

- **The resident, from losing its home.** On a VM, the home lives only on
  the VM. Without backups, losing the VM means losing the resident. So no
  VM resident is reported ready until a verified backup of its home, with
  its graph checkpoint from the same quiesced moment, has been committed.
- **Residents from each other.** A compromised resident must not be able
  to read, write, replace or delete another resident's backups, must not
  be able to replace or destroy its own history, and must never see the
  house's S3 or Hetzner credentials.
- **Daniel's isolation choice, from quietly degrading.** With the switch
  on, a resident either gets a VM or isn't created. It never ends up
  local without anyone noticing.
- **The house's money.** A switch that buys a server for every resident
  needs a ceiling. Any server that might exist keeps counting against
  that ceiling until its deletion is confirmed, including servers whose
  resident was deleted mid-purchase.

It does **not** protect residents from the house. The house holds the
Hetzner project token and stays root over every VM.

## Site setting

`settings.new_residents_on_vm` (boolean, default false) and
`settings.vm_resident_limit` (integer, default 0). Both go on Site Admin →
Settings. The page states the v1 exclusions next to the switch.

**With the switch on, creation either gets a VM or is refused before
anything is committed.** The create form and `POST` refuse with a plain
reason when:
- procurement isn't configured (image, keys, house domain, command
  channel)
- the cap is reached
- the resident is outside v1:
  - imported homes (the reviewed home would have to reach the VM; that
    comes in a later slice)
  - subscription-OAuth providers (those residents stay creatable only with
    the switch off)

  House inference and API-key providers are in v1. API keys go to the
  resident's own container as env, the same trust as locally.

Nothing falls back to local. If Daniel later wants "VM where possible,
local otherwise", that's a separate policy.

**Cap.** The cap counts placements with `backend: hetzner_cloud` that
aren't `retired`, plus any placement whose procurement operation is
unresolved or whose deletion is unconfirmed. Creation takes the
procurement admission advisory lock, counts, and creates the placement in
the same transaction, so two simultaneous births can't both take the last
slot.

**Turning the switch off** affects only births not yet committed. Births
already admitted keep going on their VM. Nothing is moved local.

## Creation flow

`HostedBirth`, when the switch is on, creates the agent and an
`AgentPlacement(backend: hetzner_cloud, state: pending)` together, then
enqueues `ProvisionVmAgentJob` instead of `ProvisionAgentJob`. The job
re-enqueues itself until it reaches done or failed. Each step reads
current state, so it's safe to re-run:

1. **Credentials.** `HostedProvisioning#prepare!` mints the outbound key,
   trigger token and restic password for a VM placement too. There's no
   local Docker step. (Slice 1, #247.)
2. **Order.** This is a new, narrow entry point,
   `CloudProcurement#plan_for_vm_birth!(placement:)`. It is the only path
   that accepts the system actor, and only for a placement whose birth was
   durably admitted while the switch was on (the placement records
   `admitted_by_setting_at`). It doesn't re-check the switch, so turning it
   off can't strand an admitted birth. It
   writes an audit-log entry and uses `approval_reference:
   "setting:new_residents_on_vm/agent:<id>"`. The admin gate on `plan!`
   is unchanged. Then `submit!` as now.
3. **Enroll.** Reconcile until the runner has enrolled and is healthy.
4. **Seed the home** (see Seed below).
5. **Mark ready, start.** Placement → ready, then `start_resident` with
   the pinned image ID.
6. **First backup** (see Backups below). Only when it is verified does the
   house set `runtime_ready_at` and enqueue `OrientNewAgentJob`.

**Turns are refused until step 6 passes.** Until `runtime_ready_at` is
set, user, scheduled and rhythm turns for a VM resident are refused at
admission. This is an explicit check in the slice that adds the job,
because I haven't verified that `provisioning` alone suppresses every
route.

**Bounded failure.** Provisioning has a deadline (default 45 minutes from
order, configurable). Past the deadline, or on any terminal failure (a
procurement refusal, an expired enrollment, a failed seed, three failed
first backups), the job stops. No start, no orientation. It sets
`sandbox_last_error`, marks the placement `failed`, and records cleanup
intent (below). Then the VM is reconciled to deletion, so a failed birth
can't keep spending. "Operator-held" is a named alternative state, used
only if Daniel asks to keep a failed VM for inspection.

## Cleanup through uncertain purchases

`AgentPlacement` gains `cleanup_requested_at` and `cleanup_reason`. These
are set when the resident is deleted, when provisioning fails, or by an
admin. Setting them never deletes the placement or its operations.

`VmCleanupJob` runs for any placement with cleanup intent, and keeps
running until the provider confirms nothing is left:
- **Operation still unresolved** (create sent, outcome unknown): keep
  reconciling. If a server turns up, carry on to deletion.
- **Server verified**: `request_delete!`, then reconcile until deletion is
  confirmed.
- **Confirmed deleted or validated refusal**: revoke the enrollment, set
  the placement `retired`, and release it from the cap.

A sweeper reports any server in the Hetzner project that no placement
claims. Reporting is all it does, because a server nobody claims isn't
ours to delete automatically. Until retirement, the placement keeps
counting against the cap.

## Seed

New runner command `seed_home`. Its payload names a seed archive by
SHA-256. The runner fetches the archive from the house over the signed
channel, the same way it fetches images (#242): scoped to the enrollment,
no redirects, bounded in size and time, and refused unless a delivered
`seed_home` names that digest. The archive is the same
`AgentIdentityExporter` tarball local residents get.

The runner keeps a seed marker so a retry is idempotent:
- It extracts into `/identity/.souls-house-seed-staging/`. Entries must be
  relative, with no `..`, and regular files or directories only (no links,
  devices or FIFOs), checked before writing. Total bytes and entry count
  are capped.
- When extraction finishes, it moves the entries into place, then
  atomically writes `/identity/.souls-house-seed` containing the digest
  (written to a temp file and renamed).
- On retry:
  - marker present with the same digest: answer `done`, idempotently. A
    lost acknowledgement leads here.
  - marker present with a different digest: `refused`.
  - volume holds anything else and has no marker (including a staging
    directory left by an interrupted run): `refused`. The volume is left
    as it is for an operator and the birth fails closed. It is never
    wiped automatically.

## Backups

**restic on the VM, through a house-side REST repository, append-only in
fact.**

**Runner side.** `backup_resident` command. The payload carries the
resident's restic password and a graph checkpoint envelope (below). The
runner:
1. refuses unless the container is running or stopped (never already
   paused)
2. pauses it
3. writes the checkpoint into a temp directory
4. runs `restic backup` over the resident's volumes, mounted read-only
   (`state` excluded, as locally), plus the checkpoint directory, tagged
   as locally
5. unpauses in `finally`

The whole command has a deadline. The unpause is attempted on every exit,
and the result reports whether the container ended unpaused. restic's
repository is `rest:http://127.0.0.1:<port>/`, a loopback-only proxy in
the runner that signs each request with the enrollment key. No new secret
goes to the VM.

**Graph checkpoint, coupled.** mnemodyne lives in the house database. The
house builds the checkpoint envelope at the moment it issues
`backup_resident`. It refuses to issue it unless the resident is idle (no
active interaction), and it holds new turn admission for that resident
until the command is answered. The envelope travels in the payload and is
written into the same snapshot as the home, so one snapshot holds both,
captured together. Afterwards the house checks, as `AgentResticJob` does,
that no interaction started during the window. If one did, the snapshot
is recorded as not ok.

**House side.** The restic REST protocol at
`/api/v1/host_runner/backup/*`. The repository prefix is
`agents/<uuid>/`, taken from the enrollment's placement and never from
the request.
- **Grammar.** Only restic's REST wire paths are accepted:
  - `POST /?create=true` (repository initialisation, the only query
    accepted; it creates nothing beyond what create-if-absent allows)
  - `config`
  - `keys/<64 hex>`, `locks/<64 hex>`, `snapshots/<64 hex>`,
    `index/<64 hex>`, `data/<64 hex>`
  - the listing endpoints `GET <type>/`

  `data/<hash>` is sharded as `data/<2 hex>/<hash>` only when it is
  translated to an S3 key, matching the layout local residents' repositories
  already use. Any other path, method or query is refused.
- **Create-if-absent.** Every POST is an S3 conditional put
  (`If-None-Match: *`). If the object already exists, the house compares
  it: identical bytes answer 200 (a retry), different bytes are refused.
  `config` and `keys/*` fall under the same rule, so they can't be
  replaced either.
- **Delete.** Only `locks/<64 hex>` under this repository's own prefix.
- **Budgets.** Each repository has a byte budget, default 20 GB,
  configurable. Bytes are counted on commit, and writes are refused past
  the budget. Each enrollment can have at most 2 backup requests in
  flight, and the endpoint as a whole has a cap so backups can't take
  every Puma thread. Each request has a size cap (restic packs are about
  16 MiB by default) and a timeout.

**First backup = verified.** A backup counts toward the readiness gate
when the command answered `done`, the reported snapshot id exists in the
repository listing the house reads directly from S3, that snapshot's
tags carry this agent's uuid, the checkpoint digest it reports matches
the envelope the house issued, and no interaction overlapped the window.
The house records `AgentBackupSnapshot` with the checkpoint digest, as it
does for local residents.

**No automatic prune for VM residents in v1.** restic documents that,
in append-only mode, someone holding the password can forge snapshots
with chosen timestamps. Daily/weekly/monthly `forget` can then delete real
history in favour of forged snapshots
([restic: security considerations in append-only mode](https://restic.readthedocs.io/en/stable/060_forget.html#security-considerations-in-append-only-mode)).
So VM repositories grow until the budget is reached. Hitting the budget
alerts the admin, and backups stop with a visible error instead of
evicting history. A safe retention policy is a separate design, with its
own seam: today's `prune!` requires local placement.

Alternatives considered and set aside:
- **IAM-scoped S3 credentials on each VM.** Needs per-resident IAM, and a
  VM could still delete its own history.
- **Storage Box sub-accounts.** Not append-only, and adds a provider.
- **Stream a tar to the house.** Every backup would be a full transfer.

## Restore check

Before the switch goes on in production: one throwaway VM resident is
born, seeded and backed up. Then a disposable restore runs on the house
(`restic restore` into a scratch directory, using the house's own S3
credentials and the resident's password). The check compares the
identity files against the seed archive and the checkpoint digest
against the recorded one. Then everything is deleted. This is backup
evidence, not migration work.

## Image updates

Not in this slice. When the image changes, VM residents keep their pinned
image until they get a new `start_resident`. Site Admin will show each VM
resident's pinned image ID, and whether it differs from the house's
current one, so stale VMs are visible. Rolling updates is a follow-up.

## Slices

1. VM credentials in `prepare!` (#247).
2. Setting, cap, refusal-not-fallback, and visible exclusions (UI + API).
   The switch is still unusable here: turning it on refuses every birth
   with "VM provisioning not available yet" until slice 5 lands.
3. `seed_home`: house archive endpoint, runner handler, marker.
4. Backup REST endpoint (grammar, create-if-absent, lock-only delete,
   budgets), runner proxy, `backup_resident`, the coupled checkpoint and
   the verified-snapshot check.
5. `ProvisionVmAgentJob`, `plan_for_vm_birth!`, turn refusal until ready,
   the deadline, `VmCleanupJob` and cleanup intent, the pinned-image
   column in Site Admin.
6. Live check in production with `vm_resident_limit: 1`: birth, answer,
   restore check, delete, confirm nothing is left. Then Daniel flips the
   switch.

Every slice goes to Mira for review before merge. Master auto-deploys, so
nothing that can spend runs until slice 5, and nothing is switched on
until slice 6.

## Open questions

1. With the switch on, imported and subscription-OAuth residents can't be
   created at all. Is that acceptable to Daniel until the slice that
   covers them? (It follows from "no silent local fallback".)
2. The server type comes from credentials (cx23 in the pilot). Per
   resident later; not in v1.
3. The 20 GB backup budget and 45-minute provisioning deadline are
   guesses. Both are settings.
