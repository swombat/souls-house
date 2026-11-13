# VM resident backups

Slice 4 of [new residents on VMs](2026-10-09-vm-hosted-new-residents.md).
This does not enable VM births or authorize turning the site setting on.
The runner source and `backup_proxy.py` must both ship in the Rails image
and in the VM's cloud-init document. Since #593 an enrolled runner that
knows `update_runner` is updated through its command queue when the house
ships a different bundle: it fetches the bundle by digest, refuses any entry
over 256 KiB unpacked (never a prefix), self-checks it in
`versions/<digest>-<random>/`, and activates it by one atomic rename of the
`current` link that both entry files resolve through, keeping the last pair
behind `previous`. A runner still on its birth files is first moved behind
`current` without changing what runs. A runner older than `update_runner`
needs one install by hand.
Cloud-init carries an XZ-compressed, deterministic two-file tar bundle and
extracts it before enabling the runner. Python's standard AST unparser removes
comments, redundant formatting and docstrings (since #593); each module is
reparsed and its AST must equal the reviewed original with docstrings removed,
and a module that reads `__doc__` is refused, or packaging
fails before purchase. Traceback line numbers change, not executable behavior.
`python3` is explicit in the Rails image; `xz-utils` already is and is also
explicitly installed on the VM. Tests prove AST equality and exercise the
packaged Python modules, not just the readable source.

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

## What a snapshot carries (13 Nov)

- **Postgres, dumped minutes earlier.** A server with its own PostgreSQL
  (`souls-house-postgres`, configured by `/etc/souls-house-postgres-backup.json`
  naming `home_mount` and `databases`) is dumped by the backup itself, under
  the house's idle hold and before the pause, into
  `<chaos volume>/postgres-backups/<generation>/`, which the chaos role
  carries. Each database is `pg_dump -Fc` and checked with `pg_restore --list`,
  roles are `pg_dumpall --globals-only`, and a receipt and `current.json`
  are written last. The new generation and the one before it are kept. The
  config must name this resident's own chaos volume. It replaces the
  hand-installed 15-minute timer of 11 Nov, of which 95 dumps a day were
  never shipped; the timer is disabled on both VMs.
- **The latch stays, loudly.** A generation left `.incomplete` (an interrupted
  dump) refuses every later dump until an operator has looked; nothing
  deletes it. The backup still snapshots everything else, but it is recorded
  as failed with `Postgres dump failed: incomplete generation … retained;
  operator review required`, so the health rhythm sees it every night.
- **Claude Code transcripts.** `state/claude/projects`, and nothing else of the
  state volume, is mounted read-only at `/data/state/claude/projects` through
  Docker's `volume-subpath`, which resolves inside the volume and refuses an
  escape. Provider credentials and tailscale state stay out. A resident
  without that directory is snapshotted as before.
- **A persistent restic cache.** Each resident has a `<container>-restic-cache`
  volume, the tool's only writable mount. Restic keeps it encrypted. Without
  it every backup re-read the parent snapshot's trees one ranged request at
  a time through the house (VM, house, S3, serially), and on 13 Nov that
  alone outran the work deadline: Alanis had no verified snapshot since
  29 Oct, and every failure read only "Runner backup failed". Failures now
  carry the runner's own value-free error.

The command carries the exact checkpoint JSON in the existing encrypted
command payload. Its whole-file SHA preserves Ruby's bytes across Python;
the envelope's separate payload digest keeps the existing graph contract.
For residents without a house graph, the checkpoint file is literal `null`.
Command answers remove the encrypted payload as before.

The runner uses a digest-pinned restic image and a loopback-only signing proxy.
No S3 credentials reach the VM. The tool container uses host networking to
reach loopback, not the resident's Docker network. The proxy signs the
original full target, including the sole accepted query `?create=true`;
there are no redirects or ambient HTTP proxies. Validated, bounded single
byte ranges are forwarded and must receive a matching 206 response; a
whole-pack 200 is never silently substituted. This is needed for subsequent
backups to read their parent. VM restores are not in this slice.
The read-only tool receives only `DAC_READ_SEARCH`, allowing it to read
agent-owned private files without write privileges.

## Verification and failure

Restic's stored snapshot objects are encrypted. The house runs read-only
restic (`--no-lock --no-cache`) against S3 to prove the exact snapshot ID,
resident tag and stored checkpoint bytes/digest. Merely finding an S3 key
or receiving `done` from the runner is insufficient. A snapshot is not ok
if any interaction overlapped the held window.

`Backup::VmBackupCheckJob` polls and settles the result. Scheduled backups
use the same issuance path and never run local `forget`/prune on a VM.
A known failed backup whose tools are stopped and runtime is unpaused releases its
hold. Unknown runtime state or a missed deadline records failure and
**retains** the hold; a timer never proves containment.

Provisioning cleanup can call
`Backup::VmResident.release_after_retirement!(placement:)` only after
confirmed retirement and runner revocation. For an interrupted established
resident, a durable runner marker records the exact command before taking
custody of the pause. On restart or before its next command, the runner removes
the strictly named backup tools, verifies their absence, unpauses only the
marked resident and inspects its final state. A signed heartbeat carries an
acknowledgement tied to that command and live enrollment; only this known-state
proof can release its failed hold. Recovery does not bless the snapshot.
Failure to contain tools preserves the marker and hold. SIGTERM traverses
cleanup; heartbeats continue during long commands. Uncertain turn submissions
remain busy until their runtime ledger proves completion, not until a timer
expires.

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
- Request objects: 32 MiB; database statements and S3 connection/read
  operations are bounded separately, without asynchronous Ruby interruption
  of a pooled database connection.
- Runner backup: ten minutes, including a reserved cleanup/unpause window.
  Unpause retains a ten-second attempt budget and one retry even after an
  overrun; containment takes precedence over a strict wall-clock cutoff.
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
live recovery proof. Include an agent-owned 0600 file, a second backup using
the first as its parent, and an interrupted-backup recovery.
