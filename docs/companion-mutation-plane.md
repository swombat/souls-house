# Companion S2 protocol — candidate for review

This document describes the candidate extension, not a deployed capability.
S1 is the reviewed read plane. The paired Linux candidate integrates mutation
and user-cgroup runner primitives; no Dell acceptance is implied.

## Authority

Admission of each operation intersects the house grant and local ceiling.
Write implies read, not permission to call the execute API. **Write access to
a volume containing the service user's home must nevertheless be treated as
deferred arbitrary code execution as that user**: a resident can modify
`.bashrc` or other startup/configuration files that later run code when the user
loads them. This does not require an execute grant. Copy needs source read and
destination write; move needs write on both. Rename/trash need write on their
volume.

Execute requires an explicit per-computer execute grant and intentionally has
the service user's general OS authority, not a volume sandbox. **Executed
programs can rewrite `state.json`, including the local ceiling.** The companion
is not a sandbox, and the local ceiling is not an enforceable limit against an
execute-granted actor. Admission checks are not post-execution confinement.

### Human enrollment warning

Enrollment is API-only; there is no companion settings page or grant-description
endpoint. A confirmed account owner/admin creates a grant with a human API key
at POST `/api/v1/companion_enrollment_grants` (see the
[enrollment contract](companion-read-plane.md#authority-and-enrollment)).
The successful creation response includes `id`, `expires_at` and
`authority_warnings`, an array of human-readable strings for the grant creator:

- Any resident with a `write` volume adds the deferred-code-execution warning,
  even when `execute` is false. Rails does not know whether an opaque volume key
  contains the user's home, so every write grant receives this warning.
- Any resident with `execute: true` adds the full-user-authority and
  rewritable-`state.json`/local-ceiling warning, including execute-only grants.
- Read-only policies with no execute permission return an empty array.

Human-facing API clients must display these warnings with the created grant;
the response is not a new consent/acknowledgement gate or a permission change.

Candidate metadata:

- `mkdir`: `volume`, `path`
- `write`: `volume`, `path`, `mode` (`create` default, `overwrite`, `append`),
  `input_size`
- `copy` / `move`: `source_volume`, `source_path`, `volume`, `path`
- `rename`: `volume`, `path`, `destination`
- `trash`: `volume`, `path`, `quarantine`
- `execute`: `input_size`, `timeout_seconds` (1–300, default 30)

Unknown keys are refused. Paths are relative to a verified granted mount;
quarantine must be an owned writable directory on that same mount, not a
cross-volume fallback. No-overwrite is the default. Linux primitives must
report partial copy/move outcomes honestly, including copied/source retained.

## Inputs do not become permanent arguments

File bytes, argv, cwd and stdin never belong in retained operation arguments
or a Cable frame. `write` and `execute` use a two-step, bounded HTTP input:

1. A resident creates the pending operation with metadata and exact
   `input_size` (at most 8 MiB). It consumes a concurrency slot immediately.
2. That same resident PUTs raw `application/octet-stream` to
   `/api/v1/companion_devices/:device_id/operations/:id/input`.
   A size mismatch, second upload, expired deadline, changed grant or pause
   refuses it. Only then can the persisted operation dispatch.
3. The device GETs `/api/v1/companion/operations/:id/input` using its device
   credential plus epoch/revision headers. Its dispatched operation and
   current authority are rechecked under device→operation locks. It consumes
   the input once; a lost download is an operation failure, not a replay.

Write inputs are raw bytes. Execute input is UTF-8 JSON with `argv` (nonempty
string array), `cwd` (string) and optional `stdin_base64`. No implicit shell.
The Linux parser validates lengths/NULs and separately caps decoded stdin.
The complete encoded input must fit the 8 MiB cap. Temporary input bytes are
filtered from SQL logging and expire no later than the operation's deadline;
the minute sweeper removes expired bytes. They are plaintext in the database
and may survive in WAL/backups, as with S1 result bodies.

An operation's deadline starts at creation, not after upload. Execute's
deadline is at most 300 seconds; network/upload time reduces available runtime.
No reconnect replay. Pause/revoke suppress input/results when observed; bytes
already delivered cannot be recovered.

Execute results travel through the existing raw, device-only HTTP result
endpoint, capped at 8 MiB (not S1's 64 KiB JSON limit). Each stdout/stderr stream
is capped at 1 MiB by the runner, with explicit truncation and exit status.
Arbitrary output and arguments must not enter logs/audit.

## Linux semantics and explicit limits

Create and overwrite use anonymous `O_TMPFILE` staging, fsync the complete file
then atomically publish; unsupported staging fails closed. Overwrite replaces
an existing regular inode with a new 0600 file, not preserved ACLs/xattrs or
in-place truncation. Append requires an existing singly-linked regular file
and may leave a reported prefix after interruption. Namespace durability
across power loss is not promised.

Rename/trash/move accept singly-linked regular files only. **Directory
rename/trash/move are refused**, not complete v0 directory support. Quarantine
must already exist, owned by the service uid, private 0700 and writable on the
same verified mount. A random receipt name is returned; no cross-mount trash
fallback or permanent-delete tool exists.

Copy is regular-file-only and capped at 8 MiB total; source identity,
size/mtime/ctime and ancestry are rechecked. Destination never overwrites.
Cross-volume move copies first, then rechecks and unlinks the source; a
post-copy failure returns `copied_source_retained`. Same-volume move uses
atomic no-replace rename. Mutation receipts distinguish committed/partial
effects from pre-commit failure, including failed staging cleanup.

Like the read plane, this is **not an atomic boundary against hostile local
namespace/content writers**. Linux cannot compare an expected inode in the
same unlink/rename syscall. Pinned fds and ancestry/inode rechecks deny known
protected live aliases but cannot eliminate that local-writer race.

Execute uses systemd 254+ transient user services with control-group kill,
bounded cleanup and stdout/stderr drains. Output is base64 in JSON, at most
1 MiB per stream plus truncation flags and exit status. Supervisor errors
return `supervision_failed`, not a claim that nothing ran. A hung manager can
leave cleanup unconfirmed; full-user-authority hostile programs can explicitly
start other user units. The manager login environment is trusted, PATH is
fixed, and shell profiles are not loaded. See the companion runner README.

## Removal

Device-only POST `/api/v1/companion/revoke` revokes only the credential's own
device, including while paused; it is idempotent for that current credential.
An old rotated credential is not accepted. `companion uninstall --user`
sets the local deny marker, stops the service, revokes remotely, durably
removes credential material, disables/removes the unit and reloads the user
manager. It retains non-secret ceiling/audit/uninstall state and personal files.
A remote failure preserves credentials and local deny; there is no silent
force-removal fallback. An outstanding lost rotation response may require
credential recovery or human revocation before uninstall can finish.

## Remaining gates

Exact-head reciprocal review and broad regression receipts precede merge.
Actual systemd child-tree kill, Dell install/SSH trust, user-authenticated
enrollment, Btrfs identity/subvolume protection, mount and linger checks remain
acceptance gates. Fake supervision seams and protocol-only Rails fixtures are
not proof of Dell supervision. This candidate does not complete Linux v0.
