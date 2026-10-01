# Swift portable core — issue #121

This is a bounded **portable core**, not a working iOS app or login prototype.
Swift 6 actors own one session/account/conversation scope. Foundation is used for
JSON, dates, UUIDs and the fake store lock; there is no URLSession,
FoundationNetworking, SwiftUI, SwiftData or other Apple-platform dependency.

## Contracts implemented

- `changes` bootstrap is explicitly cursor zero; pagination advances only to
  `next_since`. Whole pages validate before application. History and accepted
  sends merge by message revision but never advance the changes cursor.
- Discard markers strip content. Stale states, absent history rows and stale send
  responses cannot restore discarded messages. Unknown fields are ignored;
  unknown role/author values confer no modification permission. The local
  permission hint is not authorization: Rails remains authoritative.
- Submission generates a UUID and exact JSON bytes, including ordered attachment
  references, and saves them before delivery. Retries send stored bytes, not an
  edited draft. Failed transport/decoding/acknowledgement retains pending work.
  A send response means server acceptance, not a resident read or wake.
- `OutboxStore` is a reusable synchronous transactional seam. It requires thread
  safety and real durable commits in a future implementation. No actor suspension
  occurs between checking the session and saving/removing/clearing entries.
  `InMemoryOutboxStore` is explicitly a **non-durable test fake**.
- Logout invalidates the generation before local cleanup; late fetch/send
  responses cannot apply. Failed cleanup is surfaced and leaves the core inactive.
  New authentication requires a new session ID and core; it never silently imports
  the previous session's queue. A restart of the *same* authenticated session may
  explicitly retry its persisted queue. Cleanup is session-wide: the future session
  coordinator must stop routing new work and invalidate **every** core belonging to
  that session. Calling logout on one conversation is not logout of its siblings.
  A session ID is a local storage partition, not account or server authority.
- Invalidations during fetch cause a follow-up; bursts coalesce. Foreground and
  subscription-confirmed reconnect trigger reconciliation. `repairTick` implements
  the 30-second active/foreground/online repair rule with supplied monotonic time.
  It does **not** install a scheduler: the lifecycle adapter must invoke it.

## Tests

Tests use synthetic `../fixtures` directly via source-relative paths, plus narrow
inline malformed payloads and continuation-gated transports. No sleeps, network,
credentials or real resident data. Linux Swift 6.4.0:

```sh
env -i HOME=/home/agent \
  PATH=/home/agent/.local/share/swiftly/toolchains/6.4.0/usr/bin:/usr/bin:/bin \
  LD_LIBRARY_PATH=/home/agent/work/native-toolchains/libs/usr/lib/x86_64-linux-gnu \
  /home/agent/.local/share/swiftly/toolchains/6.4.0/usr/bin/swift \
  test --build-system native --jobs 2
```

The explicit native build system is this host's documented linker workaround
(Swift warns it is deprecated). These host paths are test toolchain locations,
not application configuration.

## Deferred integrations / limits

No HTTP/status/error adapter, OAuth/PKCE/refresh, browser callback, Keychain,
socket subscription, lifecycle timer, durable storage/migrations, atomic durable
cache/outbox conversion, draft storage, attachment upload/download or platform UI.
Transport must return bytes only for successful accepted sends and perform auth
and HTTP error classification itself. Pending overlays are cleared only after a
validated successful send response; reconciliation alone does not acknowledge
outbox entries. Cleanup currently covers the core cache/outbox only: credentials,
drafts/private files and remote revocation belong to future session integration.
Single-session ownership and correct routing of socket/history callbacks are
adapter responsibilities. Reads are in memory, bootstrap always starts at zero,
and very long reconciliation can require many requests.

No Xcode, iOS SDK, device, signing, accessibility, process-death durable-store or
production-network acceptance has been performed. Foundation date decoding
accepts server fractional ISO timestamps and non-fractional ISO timestamps; date
values are for presentation, never ordering/checkpoint decisions.
