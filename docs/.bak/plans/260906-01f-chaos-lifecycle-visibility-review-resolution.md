# Lifecycle review resolution

**Date:** 2026-09-06

Responds to Lume's [01e implementation review](260906-01e-chaos-lifecycle-visibility-implementation-review-from-lume.md).
Changes stay in `souls-house-1`; no deployment or production queries performed.

## Resolved

1. **Pre-send failures:** missing callback credentials (pre-invocation failure),
   connection refused, unreachable host/network, DNS failure and connect timeout now
   finish the run as failed immediately, expire the unused reporting credential,
   and release admission. Read timeout, EOF and connection reset remain
   uncertain. Error handling locks/reloads the run before deciding.
   Tests cover both the error classification and actual request orchestration
   with synthetic Docker-start and refused-connection failures.
2. **Read-path locks:** reconciliation returns before taking a write lock when
   the run is terminal, legacy, or its deadline has not elapsed. The locked
   path still reloads/rechecks before updating.
3. **422 recovery:** rejected multi-event batches are split into individual
   events. Invalid detail is omitted and counted; valid registration and
   completion events are preserved. A recovery heartbeat exposes the loss.
   If an individual registration, fallback or terminal control event is
   rejected, reporting stops with a sanitized warning: silently dropping one
   would invalidate later attempts or falsely imply completion was recorded.
   Authentication and other non-retryable routing/protocol errors still stop
   reporting. Consent revocation also clears isolated narration retry batches.
4. **Legacy rows:** only live-run rows enter the separate unbounded unfinished
   slice. Historical legacy rows remain eligible for the bounded latest-20
   history, not permanent additions outside that slice. No production data
   backfill is needed for this fix.
5. **Attempt race / late startup:** attempt transitions are locked; stdout
   projection checks its captured attempt identity under that same lock, so
   a straggler cannot acquire the new attempt's identity. Oversized-line loss
   accounting is locked too. Callback configuration now locks and checks the
   preparation budget/state immediately before invocation; expired preparation
   cannot start a late trigger. We keep the ten-minute preparation budget,
   rather than silently enlarging it.

## §2 deferred with a qualification

`Agents::Sandbox#running?` currently implements:

```ruby
result[:ok] && result[:stdout].strip == "true"
```

Therefore false means either **confirmed not running** or **Docker inspection
failed**. It is not presently an authoritative death signal. Calling it on each
poll would also put Docker I/O on a chat read path.

A safe follow-up should introduce a bounded, tri-state supervisor observation
(running / confirmed stopped / inspection unavailable), fence it against
container recreation and pending startup, and reconcile outside viewer polling.
Confirmed stopped can then shorten admission holds without treating a Docker
partition as proof that the resident exited. The finite unknown-release policy
remains in place meanwhile.

## Deployment boundary

These fixes address the merge blocker and the recommended pre-enable code
changes. Deployment still requires publishing the two repositories, building
the resident image with Chaos `255aad031` or a descendant, migrating Rails,
updating containers between invocations, and the production TLS/proxy and live
canary checks in [01d](260906-01d-chaos-lifecycle-visibility-implementation.md).
No public endpoint probe substitutes for checking the callback from a resident
container. In particular, verify no redirect and adequate body limits on the
authenticated callback route.

## Verification

- Full Rails suite: **2,100 tests / 10,600 assertions**, no failures or errors.
- Full browser suite: **19 journeys passed**.
- Synthetic Python reporter suite: **14 tests passed**, including 422 isolation,
  rejected registration, consent revocation during isolated retries, and
  protection against an endless rejected-heartbeat repair loop.
- Changed Ruby files: **6 files, no RuboCop offenses**, using the previously
  documented parser compatibility configuration.
- `git diff --check` passed. No frontend or Chaos code changed in this follow-up.
