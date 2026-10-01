# Portable Kotlin core — issue #121

Independent Kotlin/JVM prototype, not a Swift translation or an Android app.
Kotlin 2.2.21, JDK 21, Gradle 8.14.3. Coroutines and kotlinx JSON are pinned
in `build.gradle.kts`; no Android SDK is required.

## What is implemented

- A session-owned conversation repository with immutable `StateFlow` snapshots
  and suspend transport/storage seams. Transport is typed; `Wire` decodes the
  supported v1 message/history/changes/send JSON subset, ignoring additive keys.
  IDs remain opaque strings, revisions are signed nonnegative `Long` cursors,
  message revisions must be positive, dates preserve microseconds.
- Pagination uses only `next_since`, validates increasing page revisions and
  preserves empty-page cursors. History and send responses never advance the
  checkpoint. Newer revisions win; discard markers drop body/date/author fields
  and stale history cannot resurrect them.
- Unknown message roles/authors cannot satisfy the narrow own-human-message
  modification **presentation hint**. This hint is not account authorization;
  the server still checks current membership on every request. No capability or
  membership permission engine is implemented.
- Submitted UUID and exact JSON payload (including ordered upload references)
  are committed before transport. Failed persistence prevents send. Ambiguous
  delivery, cancellation, and failed acceptance cleanup retain the same entry.
  An accepted retry may return a marker. A failed command throws to its caller;
  it does not mean server rejection or permission to generate a new identity.
- Session generation guards late fetch/send responses after logout. A closed
  instance cannot reopen. Cache is cleared and scoped outbox cleanup is attempted;
  cleanup errors propagate without reactivating the session.
- Dirty invalidations during fetch are coalesced into a follow-up without losing
  the last event. `ForegroundRepair` tests foreground, online recovery,
  confirmed subscription/reconnect and 30-second monotonic ticks while active.
  The host must register its event handler before subscription confirmation.

Storage operations are serialized with local transitions, not with network
awaits. Storage implementations must provide short, atomic commits and cleanup.
`InMemoryOutboxStore` is explicitly a fake: restoring from the same object tests
the seam, **not disk durability or real process-death recovery**. Restoring never
automatically sends. New logins must receive new `SessionScope.loginId` values;
pending work from another login is not adopted.

## Tests

Tests read `../fixtures/*.json` directly (synthetic, backend source provenance
in the shared README), with no copied fixture set. Deterministic coroutine
tests cover pagination/discard/stale history, unknown fields/enums, dates/UUIDs,
retry acceptance/discard, persistence failure, cleanup failure, in-flight
cancellation, coalescing, logout races and foreground repair triggers.

On the prepared Linux host, from this directory:

```sh
env -i HOME=/home/agent \
  PATH=/home/agent/work/native-toolchains/jdk/jdk-21.0.12.1+1/bin:/usr/bin:/bin \
  JAVA_HOME=/home/agent/work/native-toolchains/jdk/jdk-21.0.12.1+1 \
  GRADLE_USER_HOME=/home/agent/work/native-toolchains/gradle-home \
  /home/agent/work/native-toolchains/gradle-8.14.3/bin/gradle \
  test --no-daemon --max-workers=2
```

Gradle may create a single-use build process despite `--no-daemon`; it exits at
build completion. No inherited tokens are passed to this command.

## Deferred integrations / limitations

No HTTP, OAuth/PKCE, refresh, Cable connection, background scheduler, installed
30-second timer, Compose UI/ViewModel, Room, Keystore, disk persistence, drafts,
attachment upload/download, editing/discard commands, dispatch/activity,
conversation/account discovery, signing or device/accessibility validation.
The lifecycle adapter requires host calls on one serialized coroutine owner;
it is not a running timer or a freshness guarantee. Repository network failures
propagate; reconnection/foreground/ticks or explicit commands initiate repair.
Logout here is only local core shutdown, not credential cleanup or successful
remote revocation. Attachments are exact submitted references, not a claim that
uploads completed. State is in-memory history, not a persistent cache.
Broader native app readiness cannot be inferred from JVM tests.
