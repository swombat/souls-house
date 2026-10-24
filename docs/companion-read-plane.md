# Companion: S1 read plane

Implementation for #401 and `swombat/souls-house-companion#1`. This is a
reviewable foundation, not a Dell installation or acceptance receipt. No write
or execute operations, resident shell credential, automatic enrollment, or
ambient user credential is provided.

## Authority and enrollment

All paths below start at `/api/v1`. An enabled account's confirmed owner/admin
uses a **human API key**, not a resident token, to POST
`/companion_enrollment_grants` with `account_id`, `minting_agent_id`,
`device_request_id`, `name`, `expires_at`, and `policy`. IDs are public
obfuscated IDs. The policy is:

```json
{"residents":[{"id":"public-resident-id","volumes":[{"volume":"linux-volume:sha256","access":"read"}],"execute":false}]}
```

Volume keys come from the companion's actual discovery. `write` implies read;
S1 still refuses every write/execute operation. A separate locally applied
ceiling intersects the policy; enrollment cannot widen it. Bind mounts have
distinct keys, so different grants can overlap the same bytes.

Only the named minting resident can POST
`/companion_enrollment_grants/:id/token`. The one-use token is bound to the
device request. POST `/companion/enroll` with `enrollment_token` and
`device_request_id` returns the device credential and policy. Exact retry
recovery is bounded to ten minutes; it does not create another device.

The device POSTs `/companion/session` with its bearer credential and a fresh,
durably saved `request_id`. This rotates the credential and issues a 60-second
one-use Cable ticket. Persist the new credential atomically before connecting.
An exact lost-response retry can recover for 60 seconds; another rotation
during that window conflicts. Previous credentials are not accepted for result
uploads or general device authentication. Recovery responses are encrypted in
the database. Rotation limits stale snapshot copies; it does **not** neutralize
a currently stolen credential or an execute-granted actor. Use of the retained
previous credential after its recovery window raises a safe audit event without
automatic revocation. Only the immediately previous digest is retained, not a
complete historical reuse ledger. Expired encrypted recovery records are swept.
Paused fresh sessions return HTTP 423 without rotating; exact lost-response
recovery remains available during its original window, without authorizing
Cable ticket redemption while paused. Revoked credentials return 401.

## Connection and operations

Connect `/cable` offering `actioncable-v1-json` and
`souls-house.companion.<ticket>` subprotocols. Subscribe to `CompanionChannel`.
The server sends `ready` with a new `connection_epoch`. Device connections have
no `current_user` and all other channels reject them at the base class. A
reconnect loses outstanding operations rather than replaying them.

A permitted resident POSTs `/companion_devices/:device_id/operations` with
`operation` (`drives`, `list`, `stat`, `search`, `read`) and `arguments`.
Only `volume`, `path`, `offset`, `limit`, `pattern`, `cursor` are accepted.
The operation row precedes dispatch; four active operations maximum, 30-second
deadlines. The request envelope includes device/resident IDs, policy, revision,
epoch, operation ID and deadline.

Device results use **raw HTTP**, never Cable messages or JSON request logging:
POST `/companion/operations/:id/result`, current device bearer,
`Content-Type: application/octet-stream`, headers `X-Companion-Epoch`,
`X-Companion-Revision`, `X-Companion-Format` (`json` or `binary`).
Binary is allowed only for `read`; JSON responses are at most 64 KiB, binary
at most 8 MiB. Failures use an allowlisted `X-Companion-Error`.

The originating resident can GET the operation and GET its `/body` once.
Delivery rechecks epoch, revision, live account/resident grants, pause, revoke
and deadline. Contents are held separately from safe audit metadata, expired
for access after at most ten minutes and deleted by an expiry job. A stopped
job queue can delay physical deletion. Bodies are plaintext PostgreSQL bytea,
not application-encrypted: WAL and database backups can retain their contents
after row deletion. This job does not erase those copies. Expired encrypted
enrollment/session recovery responses are also swept every minute.
Operation deadline can make contents unavailable sooner.

Owner/admin human API PATCH `/companion_devices/:id` with `control` equal to
`pause`, `resume`, or `revoke` cancels active work on pause/revoke and emits a
safe audit event. After commit, pause/revoke forcibly disconnect the device's
Cable connections, with reconnect disabled. Paused devices cannot subscribe.
Replacing an existing epoch is separately audited as informational: an
unclean server restart can leave a stale epoch, so this alone is not evidence
of a competing client. There is no remote
widening or policy-edit endpoint in S1.

## Linux boundary and remaining gates

The separate Go client validates procfs, binds root fds to statx mount/dev
identity, and invalidates on mountinfo changes. Paths use `openat2` beneath the
root, with no mount crossing, magic links or symlinks. It protects current
state/unit/executable identities and directory ancestry. Listings/search are
bounded, single-use-cursor paged and explicitly report incomplete scope.

**Btrfs is denied**, not claimed snapshot-safe. Actual Dell filesystem,
kernel, mount UUID availability and linger are still unverified. In particular,
no acceptance claim is valid until Btrfs/subvolume exposure is assessed on the
real machine. Symlinks are not followed. Cancellation suppresses delivery but
cannot promise that a kernel I/O syscall returns promptly.

Next gates: exact-head reciprocal review and full-suite receipts; merge/deploy
the house; authorized bootstrap grant and working Dell SSH trust; safe fixture
acceptance, restart/pause/revoke/rollback evidence. S2 writes, cgroup-supervised
execute, uninstall/revoke ergonomics and final Linux acceptance are not S1.
