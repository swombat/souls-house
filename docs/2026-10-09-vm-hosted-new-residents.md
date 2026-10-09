# New residents on their own VM (design)

Daniel, 2026-10-09 (KjXOAe): one site setting, off by default. Once it is
switched on, every new resident is created on its own Hetzner Cloud VM.
Moving existing residents is out of scope; we'll come back to it later.

This builds on what the second pilot proved on 2026-10-08: ordering
(#191), runner enrollment (#192/#194), the command channel (#240), remote
dispatch (#241), and images served from the house (#242). The pilot's
gaps are listed below.

## What this protects, and from whom

- **The resident, from losing its home.** On a VM, the home lives only on
  the VM. Without backups, losing the VM means losing the resident. So no
  VM resident is reported ready until its first backup has succeeded.
- **Residents from each other.** A compromised resident must not be able
  to read, write or delete another resident's backups, and it must never
  see the house's S3 or Hetzner credentials.
- **The house's money.** A switch that buys a server for every resident
  needs a ceiling, and a resident that is deleted must not leave a server
  behind that keeps billing.

It does **not** protect residents from the house. The house holds the
Hetzner project token and stays root over every VM.

## Site setting

`settings.new_residents_on_vm` (boolean, default false) and
`settings.vm_resident_limit` (integer, default 0). The limit is a cap on
unresolved and live VM placements. Both go on Site Admin → Settings.

When the switch is on, `Agents::HostedBirth` creates the resident with an
`AgentPlacement(backend: hetzner_cloud, state: pending)` in the same
transaction. If procurement isn't configured, or the cap has been
reached, the resident is born locally exactly as today, and the
admin-visible reason is recorded. A resident is never left with no home
because of the switch.

v1 eligibility (otherwise local, with a reason):
- born hosted, not an imported home (imports need the reviewed home on
  the VM, which is a later slice)
- provider is house inference or an API-key provider. API-key providers
  get their keys as container env, as they do locally (same trust: the
  key sits in that resident's own container either way). Subscription
  OAuth residents stay local for now.

## Creation flow

`ProvisionAgentJob` branches on placement. The VM path is a new job,
`ProvisionVmAgentJob`, which re-enqueues itself until it finishes or
fails. It keeps each step idempotent and reads state rather than
remembering it:

1. **Credentials.** `HostedProvisioning#prepare!` mints the outbound key,
   trigger token and restic password for a VM placement as well. It
   skips everything that is local Docker (`Resources.validate!`, the
   container name's namespace check, sandbox host, publish ports). This
   is the step I did by hand in the console during the pilot.
2. **Order.** `CloudProcurement#plan!` / `submit!` with a system actor
   instead of an admin. The `approval_reference` is the setting plus the
   resident's id. `plan!` keeps its rule of one unresolved purchase per
   placement.
3. **Enroll.** Reconcile until the runner has enrolled and is healthy.
   The existing deadlines apply; an expired enrollment means the resident
   fails provisioning and the admin is told.
4. **Seed the home.** New command `seed_home`. Its payload names a seed
   archive by SHA-256. The runner fetches the archive from the house over
   the signed channel, exactly as the image is fetched (#242): enrollment-
   scoped, no redirects, bounded, and refused unless a delivered
   `seed_home` names that digest. It extracts only into an empty identity
   volume, and refuses if the volume isn't empty. The archive is the
   same `AgentIdentityExporter` tarball local residents are seeded from.
5. **Mark ready, start.** Placement → ready, `start_resident` with the
   pinned image ID.
6. **First backup** (below). Only when it succeeds does the house set
   `runtime_ready_at` and enqueue `OrientNewAgentJob`.

Failure at any step leaves `runtime: provisioning` with
`sandbox_last_error`, as local provisioning does. Nothing is retried in a
way that could buy a second server, because procurement already enforces
that.

**Deletion.** Destroying or permanently deleting a VM resident calls
`request_delete!` on its live procurement operation, revokes the
enrollment and retires the placement. A sweeper reports any server
whose resident is gone.

## Backups

This is the hard part, and where I'd most like Mira's eyes.

**Recommendation: restic on the VM, through a house-side REST repository.**

- The runner gains a `backup_resident` command. It pauses the container,
  runs `restic backup` with the resident's volumes mounted read-only
  (except `state`, as locally), unpauses in `finally`, and reports the
  snapshot id, size and stderr tail.
- restic's repository is `rest:http://127.0.0.1:<port>/`, a loopback-only
  proxy inside the runner. The proxy signs each request with the runner's
  enrollment key, using the same Ed25519 scheme as every runner request.
  No new secret goes to the VM. The restic password it uses is that
  resident's own password, as stored on the agent today.
- The house implements restic's REST protocol at
  `/api/v1/host_runner/backup/...`. It streams to and from S3 under
  `agents/<uuid>/`, the prefix the house already uses, with the house's
  own credentials. The prefix comes from the enrollment's placement,
  never from the request.
- **Append-only.** The house refuses DELETE for everything except
  `locks/`. Forget and prune run on the house, which already has the S3
  credentials and the password (`AgentResticJob#prune!`, unchanged). A
  compromised VM can add snapshots, but it can't destroy history.
- Restore runs the other way through the same endpoint, read-only. It
  isn't needed for v1 creation, but it is the path for a lost VM.
- Scheduling: `AgentBackupSweeperJob` enqueues `backup_resident` for VM
  residents where it would run `AgentResticJob` locally, and records an
  `AgentBackupSnapshot` from the command result. The graph checkpoint is
  house-side (mnemodyne lives in the house DB) and stays house-side.

Alternatives considered:
- *S3 credentials on the VM, IAM-scoped to its prefix.* This needs IAM
  user management per resident, and a VM could still delete its own
  history.
- *A Hetzner Storage Box sub-account per resident over SFTP.* Provider-
  enforced scoping and little code, but it adds a provider, has a sub-
  account ceiling, and isn't append-only.
- *Stream a tar to the house and run restic there.* No restic protocol to
  implement, but every backup becomes a full transfer, not an incremental
  one.

Cost of the recommendation: backup traffic passes through Puma. Pack
files are bounded (restic's default is about 16 MiB), and requests get a
size cap and a timeout.

## Image updates

Not in this slice. When the resident image changes, VM residents keep
running the old image until something sends a new `start_resident`
(start recreates the container on change; volumes stay). I'll do a
follow-up that rolls new images to VMs one at a time, after a backup.

## Slices

1. Setting + cap + VM credentials in `prepare!` + eligibility (no
   ordering yet). Small.
2. `seed_home` command, house archive endpoint, runner handler.
3. Backup REST endpoint (append-only, prefix-scoped) + runner proxy +
   `backup_resident` + sweeper.
4. `ProvisionVmAgentJob` + system-actor procurement + deletion cleanup.
   After this, the switch is real.
5. Live check: switch on in production with `vm_resident_limit: 1`, create
   one throwaway resident, see it answer, delete it, confirm nothing is
   left.

Each slice goes to Mira for review before merge. Master auto-deploys, so
the setting stays off until slice 5.

## Open questions

1. House inference is off in production, so new residents currently get
   an API-key provider. Is it fine for those keys to go to the VM as
   container env? (I think yes: same trust as local.)
2. The server type for every VM resident is the one in
   credentials (cx23 in the pilot). Should it be per resident at some point? Not in v1.
3. Is the append-only REST proxy worth the code over the Storage Box
   option?
