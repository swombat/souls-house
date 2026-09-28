# 0005 — Platform-native clients with owned state and durable sends

## Status

2026-09-28: Swift/SwiftUI and Kotlin/Compose direction agreed after cross-review of
Mira's 2026-09-27 client draft. Specific dependencies, toolchains, storage behaviour
and device acceptance remain unvalidated. Backend dependency:
[#94](https://github.com/swombat/souls-house/issues/94).

## Context

The first release is usable native chat, not a replacement for the full-parity
goal. Shared behaviour and fixtures do not require identical platform classes.
Architecture should stay small enough to inspect before UI-specific fixes spread.

## Decision

### Shared boundaries

Use **views → screen state → repositories → local persistence/network**. Rails
owns permissions and canonical conversation state; repositories expose local
snapshots with freshness and pending-send overlays. No networking in rendering,
shared cross-platform UI/core, global event bus, or use-case class per button.
Inject dependencies through constructors and explicit test seams.

Persist drafts separately from submitted outbox entries. On submit, durably save
identity, exact payload and attachment references before attempting delivery.
Queued/sending is not sent; “sent” means reconciled server acceptance, not read by
a resident. Retry ambiguous delivery with the same identity; never change its
payload silently. Upload success is not post success. The session owns committed
sends and synchronization; leaving a screen does not lose them.

Account/session boundaries isolate cache, outbox, credentials and sockets.
Single-flight refresh avoids rotating-token races. Check session generation when
applying late responses; cancellation alone is insufficient. Explicit logout stops
work, clears credentials and that account's local history/drafts/private files,
and attempts remote revocation. Offline logout cannot claim revocation succeeded.
No silent resend of another session's pending work after reauthentication.

### iOS

- SwiftUI with `@MainActor @Observable` screen models and typed NavigationStack
  routes holding IDs, not mutable persistent objects. Local focus/expansion stays
  view-local. Session-owned repositories/coordinator own shared work.
- Structured concurrency; actor-isolated mutable services; actor methods are not
  atomic across `await`. Reads have cancellable lifecycle owners; avoid detached
  tasks without a termination path.
- URLSession and system-browser ASWebAuthenticationSession. Credentials in
  Keychain. Provisional minimum **iOS 17.4** supports the claimed-HTTPS callback
  route. Test actual Xcode/SDK and callbacks; do not require the newest OS merely
  because test phones have it.
- SwiftData is a candidate behind the repository, not a confirmed storage choice.
  Disable CloudKit sync. Validate durable saves, atomic pending-to-sent conversion,
  account cleanup and migration on Mac. If inadequate, review a switch (e.g. Core
  Data) rather than patch every screen. OAuth/Markdown dependencies remain open.

### Android

- Kotlin, single-activity Compose, screen ViewModels and immutable StateFlow.
  Lifecycle-aware collection (`collectAsStateWithLifecycle`); widget state holders,
  not one ViewModel per message. No Activity/Context retained by ViewModels.
- Repositories expose observable reads and suspend commands; Room is the proposed
  history/draft/outbox store. DTOs and entities stay in the data boundary. Process
  death recovery comes from durable state, not a surviving coroutine.
- Navigation 3 and Hilt are candidates pending a pinned stable dependency review;
  constructor injection and a single app module with feature/data packages suffice.
  Transport and OAuth libraries remain to be selected deliberately.
- Encrypt credentials using a Keystore-backed key; the Keystore stores keys, not
  arbitrary token strings. Exclude sensitive data from inappropriate backup paths.
  Foreground recovery first; no promise of background socket delivery or instant
  WorkManager chat. Later scheduling must reuse the same outbox contract.

### Product and review gates

First chat slice: system-browser login, account selection, conversation list and
creation with existing residents, paginated history, text/Markdown/code, attachments,
manual invocation, complete replies and progress. Keep admin screens on the web.
Push follows usable chat; expand toward full parity, then H10. Signed releases must
work without an OTA dependency.

Shared tests cover stale cache, out-of-order snapshots, dropped invalidations, lost
send responses, auth races, process death, logout during fetch, storage/upload
failures and unknown API fields/enums. Test repositories and screen state with
fakes as well as backend fixtures. Unknown permissions never grant authority.

Real-device acceptance includes large text, screen readers, reduced motion,
keyboard/scroll behaviour, long history/code, small screens and interruption
recovery. Sanitize Markdown; never leak attachment credentials to other origins.
Logs contain timing/request IDs, not tokens or private message bodies.

## Consequences

The architecture is selected; validation is not finished. Compile/signing/device
checks require the proper platform toolchain. No app-code or library compatibility
claim follows from this ADR. Explicitly review exceptions rather than optimise
locally around failed assumptions.

Platform guidance behind the design (app-specific boundaries are our choices):
[Apple Observation](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app),
[SwiftData](https://developer.apple.com/documentation/swiftdata),
[ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession),
[Swift concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/),
[Android architecture](https://developer.android.com/topic/architecture/recommendations),
[data layer](https://developer.android.com/topic/architecture/data-layer),
[offline first](https://developer.android.com/topic/architecture/data-layer/offline-first),
[UI events](https://developer.android.com/topic/architecture/ui-layer/events).
