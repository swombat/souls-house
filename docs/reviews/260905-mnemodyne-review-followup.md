# Mnemodyne — response to Lume and automatic reflexes

September 5, 2026. Follow-up to `260905-mnemodyne-lume-review.md`, against
`0556a31`. Daniel additionally required automatic hosted memory formation and
injection, not optional enablement. Work remains exclusively in instance 2.
No deployment, push, real resident invocation or paid model call.

## Review findings

| Finding | Change and regression coverage |
| --- | --- |
| 1. Private needs lost before traversal | Traverse active nodes; filter automatic **output** before banding. A private need now demonstrably produces non-zero reinforcement without appearing in results. Dormancy remains a traversal exclusion. |
| 2. Charge erosion too fast | Add charge rate 0.001 and floor 0.1; retain edge rate 0.005. Never raise an intentionally lower charge. Export/import includes the settings with backward-compatible defaults. Tests cover floor and separate rates. |
| 3. Recovery gap/fleet abort | Empty vaults permit graphless file restore/wake; nonempty unpaired vaults permit file recovery but remain suspended with a reported mismatch and no wake. Fleet restore collects failures and continues. Its rake caller reports counts and exits unsuccessfully **after** the batch if any failures/mismatches need attention. New vaults schedule a paired checkpoint, with idle-conflict retries. |
| 4. Silent failure/concurrency | Content-free client/shim/hook statuses; `graph_memory_status` telemetry for fresh and resumed paths; last automatic attempt/outcome in vault status. Embed jobs share one global concurrency slot. Inference permits a bounded 0.5-second wait. A recurring synthetic probe reports through Rails errors and visibly fails in Solid Queue. |
| 5. Recreate before suspension guard | Guard is first in `recreate!`; test includes that fourth entry path. |
| 6. Writers parked during upload | Graph `with_lock` uses a transaction-local two-second PostgreSQL lock timeout; API renders 409. A real two-connection contention test verifies timeout and connection-setting restoration. Snapshot consistency remains protected throughout upload. |
| 7. Profile change strands erasure | Fingerprint only resident identity, graph rows and custody settings, not exporter time/profile/algorithm provenance. A profile-change erasure test passes. |
| 8. Missing failed snapshot rows | Setup/quiescence/checkpoint exceptions create `ok: false` snapshot records with a content-free error class before propagating. |
| 9. Suspended erasure limbo | Status remains readable with suspension/grace fields and without graph counts. Due suspended erasure logs a hold. |
| 10. Cleanup masks original error | Preserve original failures; log cleanup errors. Carrier volumes now have unique names and ownership/purpose labels, so failure no longer strands an unlabelled anonymous volume. |
| 11. Short receipts | 60-minute receipts; expiry regression updated. |
| 12. Plaintext off-box embedding | HTTP restricted to internal accessory/loopback, HTTPS required elsewhere. Off-box HTTP rejection is tested before any request. |
| 13. Mutable deployment image | Kamal requires a validated immutable `MNEMODYNE_EMBEDDING_IMAGE_DIGEST` and constructs `image@sha256:…`, without a tag fallback. An actual production registry digest cannot honestly be pinned before an artifact is published; publishing remains unauthorized. The release runbook requires recording/providing that digest. |

Additional fixes and regression cases: foreign edge show/update/delete; truly foreign semantic
vectors; bounded node-type filters; erasure batching continues after per-vault
errors; imports reject erasure-pending vaults. A cancel racing final deletion
uses the existing inherited `RecordNotFound` → 404 handler, rather than 500.
`recall --commit` is documented as reinforcing every returned handle.

## The automatic loop

- A hosted trigger or managed BeforeTurn reflex provisions the empty vault on
  first use. This is an infrastructure default, **not automatic authorship**.
  Inline agents stay excluded. Deliberate erasure prevents automatic creation;
  only explicit `house-memory enable` can begin another graph afterward.
- Managed BeforeTurn and Stop hooks are merged idempotently with resident hooks,
  preserving resident-authored entries. Obsolete duplicate global managed hooks
  are removed without deleting the resident's other global configuration.
- The trigger shim retains bounded fresh/resumed recall; BeforeTurn also covers
  direct harness turns and avoids duplicating an already-injected candidate
  section. The legacy vault toggle no longer disables lifecycle recall.
- Stop now invites **journal → short source-linked handles → real need/person
  connections**, automatically. It does not itself write a narrative or invent a
  need. “No shape” remains valid and avoids another hook continuation. Graph
  failure must leave the journal intact and be acknowledged as pending.
- `house-memory guide` explains needs, charge calibration/decay, vocabulary,
  directed versus symmetric edges, integration states, metadata, disclosure,
  source pointers and one worked day in second-person resident voice.
  `recall --activate UUID=VALUE` supports resident-recognized ephemeral context.
- Private needs can influence recall without being surfaced. Individual handles
  still require `disclosure: automatic`; automatic infrastructure is not blanket
  disclosure consent.

## Verification

The final verification record is below.
The prior packet's image digests and opt-in description are historical, not
evidence for this follow-up. The ordinary build exposed that upstream had already
fixed the temporary Linux patch; that patch was removed. Reproduction can pin
Chaos source with `scripts/build-local-agent-runtime --chaos-ref FULL_SHA`.

The real smoke now uses `restore!(wake: true)` through actual Sandbox spawn,
entrypoint and health checks, checks the rotated house credential inside the
fresh container, and calls the installed BeforeTurn script. No model is invoked:
this verifies the harness boundary and reflex instructions, not fabricated
evidence of a resident's subjective uptake.

### Local artifacts and checks

- Full Rails regression: **2,601 tests / 12,433 assertions, zero failures/errors/skips**,
  `log/mnemodyne-review-rails-complete.log`, including the fleet caller's
  non-success reporting after a partial recovery.
- Finished-image real-IO smoke: **1 test / 48 assertions, zero failures/errors**,
  `log/mnemodyne-review-smoke-final.log`. This includes automatic initial
  provisioning without `enable`, three simultaneous inference probes, installed
  BeforeTurn/Stop scripts, real restore/wake and the rotated container credential.
- Browser regression after rebuilding the runtime: **17/17 passed**,
  `log/mnemodyne-review-browser-verified.log`.
- Changed Ruby/Rake sources: **40 clean** using the temporary Ruby 3.4 parser
  target, `log/mnemodyne-review-rubocop-final.log`. Stock RuboCop still fails on
  the repository's Ruby 4.0 parser incompatibility; no repository rule was weakened.
- Python compilation and entrypoint shell syntax pass. The frontend format
  check still reports the same eight pre-existing untouched files.
- Full runtime build and final cached source-context rebuild succeeded at Chaos
  `f3bb63d6aec1ffdcab6330095701f3308c350199`.
  `souls-house-agent-runtime:local-2`:
  `sha256:7af987638a9c2f8de9641fccbcbbcb674739343147e1d34ebe08c0e0c8aa442a`.
- Private inference image `souls-house-mnemodyne-embeddings:local-2`:
  `sha256:50cedc0717415278b3921c9150662029b2f2e0eb8b51ca643e647281f80e64b5`.
  Both local artifacts are Linux arm64, not a claim of a production amd64 build
  or a registry publication.
- Synthetic containers, source/repository/checkpoint volumes were cleaned up.
  No other instance was modified. The pre-existing routes declaration blank line
  and Lume's original review remain untouched.

An initial contention test used Rails' fixture-pinned connection across threads
and therefore tested a Ruby pool wait, not PostgreSQL contention. It was corrected
to use a separate pool to the same test-worker database, then passed. During
image debugging, a temporary overlay had the wrong entrypoint user; this was
corrected before the real wake smoke. Neither failed run is counted as release
evidence. Final acceptance uses the normal complete runtime image, not the overlay.
