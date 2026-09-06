# Resident lifecycle production release

Daniel authorized deployment on September 6, 2026 at 14:52 CEST.

**Status: deployed and verified at 15:34 CEST, September 6, 2026.**

## Integrated release

- souls.house: `f9f5bf4d794ede120b037f8c923fc566278a7c02`, published to master.
  Incorporates the signed-off lifecycle fixes through `d794b5f` and current
  upstream `d301037`, including Mnemodyne and the subscription-bridge fix.
- Chaos published merge: `6137adb4aba58dd7ed62f3ec828958158367bb16`.
  The resident image deliberately pins reviewed lifecycle commit
  `255aad03187ff18a74c670c6fc441f2f46dd5062`, rather than adopting additional
  unrelated kernel changes in the moving master during deployment.
- Resolved overlapping runtime/shim/routes/schema/tests by retaining both
  memory and lifecycle behavior. Regenerated local schema and route helpers.
- Combined verification: **2,228 Rails tests / 11,226 assertions**, **20 browser
  journeys**, **82 frontend unit tests**, and **35 Chaos fork integration tests**
  passed. Diff checks against upstream pass; the upstream patch file retains
  its required diff-context whitespace.

## Preflight and rollback

- Production initially ran Rails `d36cfb8420e419388505eef1888f37ef66ce6b3a`.
- All nine residents were idle at preflight. Production had ten unfinished
  legacy interactions; the reviewed bounded-history fix handles them without
  backfilling or deleting production history.
- Preserved old runtime as `helixkit-agent-runtime:pre-lifecycle-20260906`:
  `sha256:0bf892764bdbeeaf0c78d8dd677c57264b4028107b738f6c68234c7119e6bfef`.
- Fresh fail-fast full backup: all nine resident snapshots succeeded between
  12:56 and 12:57 UTC; database object
  `souls_house_production_2026-09-06_12-57-18.sql.gz`, **53,563,335 bytes**,
  independently verified in object storage.
- Built the candidate under separate `helixkit-agent-runtime-lifecycle-candidate`
  tags; existing resident image tags remained unchanged during that build.
- Deployment credentials were read into ignored, mode-0600 files in instance
  one. No credential values are recorded here or in source, and Docker build
  contexts exclude them. Other development instances were not modified.

## Completed rollout

- Candidate and production runtime image:
  `sha256:25a8c63c65bdbdd845bca088d8b87e0f027835ffd0e1fcde6e63798a369629a7`,
  amd64, labelled with the pinned Chaos commit above.
  Installed binary reports `chaos 47.3.0.1788700213`.
  SHA-256 checks of the installed reporter, trigger shim, memory client, and
  reply helper matched this checkout exactly.
- Normal Kamal deployment completed successfully with
  `SOULSHOUSE_SKIP_AGENT_RECONCILE=1`. Its runtime build reused the verified
  candidate layers. Both web and jobs run release `f9f5bf4d794ede120b037f8c923fc566278a7c02`.
- No pending database migrations. Public `/up` returned HTTP 200.
  Existing Mnemodyne accessory stayed running; the synthetic embedding readiness
  check passed with the expected profile and 384 dimensions.
- Production canary passed using the installed runtime image and actual shim
  `/trigger` route with a synthetic Chaos stream (no provider/model invocation).
  A 65,536-byte HTTPS callback probe reached Rails authentication with HTTP 401
  and no redirect. Valid callbacks showed live activity before exit, persisted
  six detail events, completed the run, and retained its visible completed card.
  The actual resident reply helper authored one correlated reply. Private
  command/output markers were absent from the public activity projection;
  callbacks did not invent a transport status.
- The canary's key, chat, resident, and container were removed. Final read-only
  checks confirmed no synthetic resident/chat records remained.
- All nine real residents were idle and reconciled through the supported
  runtime job, preserving their persistent volumes. All nine actual container
  image IDs matched the verified image, callback origins were
  `https://souls.house`, and resident health was healthy. No active residents
  were deferred or intentionally interrupted.
- Final check: nine running resident containers, healthy web/jobs and public
  endpoint, and zero failed Solid Queue executions in the preceding 15 minutes.

## Scope and operational notes

- Local browser journeys cover the collapsible/expandable UI. Production
  verification was a synthetic transport/shim/helper canary, not an authenticated
  browser session or a paid model turn.
- Lifecycle activity is automatic for supported dispatches; resident narration
  remains consent-gated and off by default. Raw reasoning and raw tool output
  are not published.
- The reviewed tri-state container observation follow-up remains deferred.
  Rollout observations failed closed on Docker errors rather than treating
  them as proof of an idle resident.
- Emergency `SOULSHOUSE_LIVE_ACTIVITY=0` disables new activity-enabled dispatches;
  retain callback readers and additive schema for already-admitted runs.
- Detailed command evidence is retained in this instance's ignored
  `log/lifecycle-*.log` files. This documentation commit follows the deployed
  application commit; it does not change the production release identity.
