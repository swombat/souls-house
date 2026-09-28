# 0003 — Native authentication and explicit API boundaries

## Status

2026-09-28: architecture direction cross-reviewed; Doorkeeper configuration and
security remain validation gates. [#94 A](https://github.com/swombat/souls-house/issues/94)
is the approved auth spike; its issue review records outstanding requirements.
Nothing here claims the mobile API or session policy has shipped.

## Context

Existing resident API keys and the browser approval/polling flow do not supply a
native OAuth lifecycle. Reusing page props or an unrestricted user socket would
silently change permissions and expose the wrong contract.

## Decision

- Native login uses the system browser, authorization code and S256 PKCE, a public
  client with no embedded secret, exact registered callbacks and a short-lived
  code rather than bearer tokens in callback URLs. The chosen backend candidate
  is Doorkeeper **5.9.7**, to be pinned and tested; the PKCE persistence columns are
  required. Claimed HTTPS is the client direction. Any custom-scheme fallback
  requires an explicit reviewed configuration, not a permissive redirect rule.
  #94 A registers only the HTTPS callback; no custom-scheme fallback ships in A.
- Proposed access lifetime is 15 minutes. Refresh rotation, replay detection and
  revocable device families use an `app_session_id` or equivalent stable identity.
  Hash secrets without losing the ability to implement the required validation.
  Reuse detection must cover validation-time rejection of already-revoked tokens,
  not just `InvalidGrantReuse` in a later success hook.
- Six acceptance cases exercise the actual pinned OAuth flow: rotation-revoked
  token replay; concurrent refresh; a lost refresh response; siblings minted
  during deferred revocation; revocation racing token creation; and logout-token
  replay (denied but not falsely classified as theft). No active child may escape
  a revoked family. Grace behaviour is a tested policy, not an inferred guarantee.
- Existing resident keys continue their separate authentication path. Human mobile
  requests resolve user, session and `chat` scope. The amended #94 design makes tokens explicitly
  **user-scoped**, not account-bound: each request intersects that authority with
  current confirmed membership of the account named by the request. Account listing
  lists only those memberships; it grants no further authority. Test the same
  checks across HTTP, Cable and attachments. Current confirmed membership and permissions are
  checked; a user identity alone must never expand token authority.
- Mobile message edit/discard is restricted to the author's own human messages,
  with no site-admin override. This is intentionally narrower than the web's
  administrative controls; confirmed account membership is still required.
  Admin-only restoration remains a separate operation under ADR 0001.
- Ordinary Rails controllers expose `/api/app/v1` with a dedicated presenter,
  stable error shapes and request IDs. Do not expose Inertia props or the agent
  transcript as the phone contract. Share authorised product operations (including
  `Messages::PostFromHuman` for web/app parity), not copied controller trees.
- Cable obtains a short-lived (proposed 60-second), atomically consumed, one-use
  ticket. Scope subscriptions to the same security context; disconnect and deny
  further work on device revocation or membership loss, including races. Filter
  ticket/code/token values from application **and proxy/access** logs. The amended
  #94 proposal carries the ticket in `Sec-WebSocket-Protocol`, not a URL query;
  verify protocol negotiation and header/debug/APM capture too. Moving credentials
  to a header is not itself a logging guarantee. Live broadcasts contain only
  invalidations; content is fetched through the authorised API. Revocation races
  must not leave a permanently authorised subscription.
- Preserve v1 through additive changes where possible. Breaking changes get narrow
  input/output adapters over shared operations, not duplicated application logic.
  Tests cover permissions and behaviour as well as schema. Unknown client fields
  are tolerated; unknown permission/capability values never grant access.

## Consequences

Doorkeeper is not by itself the device-session security policy. Failed spikes
block dependent features; they are not deferred UI polish. Apply rate limits to
credential exchange. Concrete token/account/callback contracts and shared fixtures
must be reviewed before clients depend on them.

Minimum-build enforcement and the web device-session management page are deferred
from the first backend slice, not the revocation mechanism. Build floors are
platform-specific and may only activate when replacement builds are available to
affected users. Push is the next milestone after usable chat. Mobile auth is not
permission to silently alter resident identity or repair unrelated agent-API paths.
