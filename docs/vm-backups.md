# VM resident backups

Slice 4 of [new residents on VMs](2026-10-09-vm-hosted-new-residents.md).
This does not enable VM births or authorize turning the site setting on.
The runner source and `backup_proxy.py` must both ship in the Rails image
and in the VM's cloud-init document. Existing runners are not updated by
a Rails deployment.

## Provisioning seam

```ruby
command = Backup::VmResident.issue!(placement:)
result = Backup::VmResident.status(command:)
# result[:state]: "pending", "verified" or "failed"
# result[:reason]: failure explanation or nil
# result[:snapshot]: AgentBackupSnapshot after settlement, otherwise nil
```

Issuing requires an idle resident, a healthy enrolled runner, and no
unsettled lifecycle/turn command. A `VmBackup` holds new interaction
reservations and turn admission. Memory writes, reinforcement, imports,
erasure and decay are held too, so the exported graph cannot diverge while
the runner pauses and snapshots the filesystem. Identity/chaos/repo/work
volumes are mounted read-only; private provider state is excluded as locally.

The command carries the exact checkpoint JSON in the existing encrypted
command payload. Its whole-file SHA preserves Ruby's bytes across Python;
the envelope's separate payload digest keeps the existing graph contract.
For residents without a house graph, the checkpoint file is literal `null`.
Command answers remove the encrypted payload as before.

The runner uses a fixed restic image and a loopback-only signing proxy.
No S3 credentials reach the VM. The tool container uses host networking to
reach loopback, not the resident's Docker network. The proxy signs the
original full target, including the sole accepted query `?create=true`;
there are no redirects or ambient HTTP proxies. Range reads are not
forwarded by this backup-only proxy; VM restores are not in this slice.

## Verification and failure

Restic's stored snapshot objects are encrypted. The house runs read-only
restic (`--no-lock --no-cache`) against S3 to prove the exact snapshot ID,
resident tag and stored checkpoint bytes/digest. Merely finding an S3 key
or receiving `done` from the runner is insufficient. A snapshot is not ok
if any interaction overlapped the held window.

`Backup::VmBackupCheckJob` polls and settles the result. Scheduled backups
use the same issuance path and never run local `forget`/prune on a VM.
A known failed backup whose runtime is confirmed unpaused releases its
hold. Unknown runtime state or a missed deadline records failure and
**retains** the hold; a timer never proves containment.

Provisioning cleanup can call
`Backup::VmResident.release_after_retirement!(placement:)` only after
confirmed retirement and runner revocation. No automatic release or
invented unpause is offered for a live uncertain VM.

## Storage boundary and limits

The REST endpoint scopes its S3 prefix from the enrolled placement, not
the URL. Only restic wire grammar is accepted; data sharding happens only
in S3 translation. Writes use conditional creation and compare existing
bytes for an exact retry. Overwrites are refused, including config and
keys. DELETE is available only for locks in the same repository.

Defaults, configurable through installation environment:

- `VM_BACKUP_BUDGET_BYTES`: 20 GiB per repository. Exhaustion logs an
  administrator-visible error and refuses new bytes; history is not evicted.
- `VM_BACKUP_MAX_IN_FLIGHT`: four requests installation-wide; two per
  enrollment. Both local counters and shared PG advisory slots enforce it.
- Request objects: 32 MiB; endpoint storage work: 20 seconds. S3 connection
  and read timeouts are separately bounded.
- Runner backup: ten minutes, including a reserved cleanup/unpause window.
- Verification commands: 120 seconds each, with bounded output and
  unique-name Docker cleanup.

Repository budgets are recounted under a per-prefix PG advisory transaction
lock rather than using a crash-prone DB/S3 dual-write counter. Recount is
O(repository objects), capped at one million objects; response listings are
capped at 100,000. Any separate repository writer must take the same lock.
Shared admission requires direct/session-pooled PG connections, not
transaction-mode PgBouncer.

Responses are buffered and bounded, not `ActionController::Live` streams.
The endpoint admission deadline covers storage work, not final HTTP socket
drain; ordinary server/proxy socket limits remain necessary.

Before enabling births: integrate seeding/provisioning, recheck combined
cloud-init size below Hetzner's 32 KiB limit, and perform the disposable
birth/answer/restore/delete check from the design. Unit tests are not that
live recovery proof.
