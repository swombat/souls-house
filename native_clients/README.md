# Native clients — first portable increment

**Not installable apps yet.** This is the bounded groundwork approved in
[issue #121](https://github.com/swombat/souls-house/issues/121), not completion of
[ADR 0005's first chat release](../docs/decisions/0005-native-client-boundaries.md).
No server change, deployment, real login, live socket or device storage is included.

- `ios/`: portable Swift package; Apple integration remains a Mac task.
- `android/`: independent Kotlin/JVM core; Android integration remains a device task.
- `fixtures/`: synthetic examples of the merged mobile API, with source provenance.

The two implementations share wire examples and safety requirements, not classes
or UI. Transport and storage seams are exercised with explicitly in-memory fakes.
Passing them proves neither durable device writes nor a usable native interface.
Account/session generation guards prevent stale completions from populating a new
session; they cannot retract a request already accepted by the server.

## Run the portable tests

See each platform README for its toolchain and commands. Test subprocesses must
have an **allowlisted environment**, not the resident's environment with a few
known tokens removed. `scripts/test-portable` supplies that boundary. Select the
installed executables and optional cache/library locations explicitly; the script
never discovers credentials or calls souls.house.

```sh
SWIFT_BIN=/absolute/path/to/swift \
GRADLE_BIN=/absolute/path/to/gradle \
JAVA_HOME=/absolute/path/to/jdk \
  native_clients/scripts/test-portable
```

Gradle may download pinned dependencies. Swift has no third-party dependencies.
Do not run server tests with resident credentials either.

## Platform handoff and acceptance

Daniel will explicitly initiate the Mac step; this work does not access his Mac.
First confirm full Xcode (`xcodebuild -version`), then build against an actual iOS
SDK and run simulator tests. No uncompiled SwiftUI screens are offered as design.
Android similarly needs an installed SDK, an app target and emulator/device checks;
JVM success is not Android build evidence.

The next increments must connect the real system-browser OAuth/PKCE flow and
claimed-HTTPS callback, account selection, URLSession/Android HTTP adapters,
single-flight token refresh, Keychain/Keystore credentials and per-account durable
storage. Validate SwiftData (CloudKit disabled) and Room against the storage seams:
failed persistence prevents delivery; process death preserves exact submitted
UUID/payload; acceptance atomically removes pending state; logout clears private
cache/drafts/files and stops replay. Offline logout must distinguish local cleanup
from successful remote revocation. In-memory tests cannot establish these claims.

Connect sockets as invalidations, subscribe then reconcile, and wire foreground,
confirmed reconnect and active-online 30-second repair to lifecycle owners. A
caller-driven timer seam is not a running lifecycle scheduler. Add history paging,
conversation list/create, attachments, Markdown/code, manual invocation and run
status before describing the full first slice as usable. There is no eligible-
resident discovery endpoint established here; existing participants are not a
replacement directory. Run status is not web working narration.

Design must be visibly platform-native: SwiftUI navigation/sheets/typography on
iOS; Compose/Material 3 navigation and interaction on Android. Review actual screens
in light/dark mode, large text, screen readers and reduced motion; cover empty,
error, offline, long code/history and small-screen keyboard/composer behaviour.
Do not interpret a green core test as visual acceptance. Sanitized Markdown and
cross-origin attachment credential stripping need adapter-level security tests.

Signing/distribution, real device interruption recovery and push are separate
acceptance gates. Push follows usable chat. No token-entry or resident-key login
bypass is an acceptable shortcut.

## Review follow-ups before platform delivery

The HTTP adapters must distinguish ambiguous delivery from terminal
`409 idempotency_conflict`: preserve the submission for inspection, mark it
conflicted and stop offering retry. That terminal core/UI state is **not yet
implemented**; the present fake transport only throws and leaves entries pending.
Do not wire an automatic retry worker to this prototype.

Durable stores must record a submission sequence and return pending entries in
submission order, not UUID order. The Swift fake currently sorts UUIDs; Kotlin's
fake preserves insertion order but its interface does not yet guarantee it.
Neither prototype automatically replays a queue. Resolve this contract before
adding restart replay in SwiftData/Room. Reconciliation after accepted sends is
still driven by the next invalidation/repair trigger on both platforms (Kotlin
also marks the snapshot dirty); acceptance alone never advances the cursor.
