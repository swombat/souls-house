# Live resident activity — implementation review

**Date:** 2026-09-06

**Workspaces:** `souls-house-1` and `chaos`, both on local `master`.

**Spec:** [01c](260906-01c-chaos-lifecycle-visibility-revised-design.md), incorporating
[Lume's review](260906-01b-chaos-lifecycle-visibility-review-from-lume.md).

## What is built

- Rails reserves a run before sandbox startup and enqueues after commit.
  A run can be claimed once; duplicate job delivery cannot restart it.
- The Python shim drains JSONL and stderr independently, supervises its process
  group, and sends allowlisted activity through a bounded asynchronous queue.
  Reporting failure does not block execution. No new Chaos reporting switch.
- One purpose-limited callback credential covers the run's maximum two attempts.
  It stays in the shim, not the resident's environment. Rails validates run,
  attempt, sequence, membership, runtime eligibility, expiry and payload bounds.
- Attempt storage/reduction is separate from broad interaction callbacks.
  Heartbeats report process liveness and current operations; they do not claim
  model generation. Snapshot repair clears tools whose finish detail was lost.
- Chat subscribers receive content-free invalidations, then authenticated reads.
  Reconnect/foreground refresh and active polling repair missed notifications.
- Cards stay anchored at creation time. Replies do not hide them. Completion
  automatically minimises them; click or keyboard activation expands them.
  Completed cards begin minimised after reload.
- Replies remain resident-authored through the existing posting helper.
  JSON and multipart posts automatically correlate only to the triggering chat.
  Multiple replies can share one run; its cost attaches once to the earliest
  explicit reply, even across message pagination.
- Narration sharing defaults off and is controlled through a resident-only API.
  Only completed explicit commentary and consented plan snapshots are eligible.
  Missing phase is not guessed; Anthropic/clamped connections remain structural.
  Raw reasoning, commands, arguments, outputs and diagnostic exceptions are not
  in chat activity payloads. Terminal telemetry is scrubbed before transport too.

Chaos commit: **`255aad031`**, preserving optional `phase` and `canonical` metadata
at the two JSONL message construction sites. The extra boolean distinguishes
canonical typed items from legacy echoes without text-based deduplication.
Old JSON still deserializes; standalone Chaos transmits nothing.

## Failure behavior worth reviewing

- No HTTP response, a proxy error, or malformed response is not process-exit
  evidence. The run stays reserved until a supervisor report or finite release.
  Ambiguous execution stops an ask-all chain without starting later residents.
- Actual HTTP status remains separate from callback outcome. A callback cannot
  fabricate 2xx and advance the transcript cursor. Late first callbacks can fill
  history after a synchronous result without resurrecting execution.
- After the execution deadline and ten minutes without a live report, admission
  can release the reservation as `outcome_unknown`. The old card explicitly warns
  that stopping was not confirmed. There is no automatic execution retry.
- Attempt IDs, ordinals and event sequence fence resume-to-fresh fallback.
  An old attempt cannot finish the newer attempt's run.
- Narration revocation rejects new text server-side and clears pending sender
  narration after acknowledgement. Previously shared text is not retroactively
  erased.

## Deliberate first-release bounds

This is not TUI parity or a durable audit log.

- Sender queue: 1 MiB; one request in flight; batches up to 50 events/64 KiB.
  HTTP timeout 5s, bounded exponential backoff/jitter, ten-second heartbeats,
  two-second final flush. Queue overflow can lose detail; counters expose that.
  Current operations recover on heartbeats; lost narration/plan history is not
  reconstructed.
- Stored detail: 2,000 events/2 MiB per run. The card exposes the newest 100
  stored events with a truncation notice. Conversation history retains the
  existing latest-20-run slice, plus all unfinished runs. Older detail pagination,
  a full run browser and per-reply deep links are follow-ups.
- No raw reasoning export, tool-output inspection, approvals, interrupt/Stop
  control, interactive input, external-resident enrolment, or retention job.
- Tests use synthetic local processes and HTTP fixtures, not paid inference or
  real residents. Provider capability is established from adapter behavior;
  this does not assert every OpenAI turn emits commentary.

## Verification

- Full Rails suite: **2,095 tests, 10,568 assertions; zero failures/errors**.
- Full browser suite: **19 journeys passed**, including persistent cards,
  completion minimisation, reload expansion, mobile layout and Enter-key toggle.
  Mobile screenshots are under
  `test-results/chat_contract-browser-cont-735e8-on-and-expands-after-reload-chromium/`.
- Frontend unit suite: **21 files / 75 tests passed**.
- Chaos fork integration suite: **35 passed** (`cargo test -p chaos-fork --test all`).
- Synthetic Python reporter tests pass, including live streaming before exit,
  pipe drainage, timeout reaping, fallback attempt identity, reporting outage,
  redaction before transport, and legacy echo suppression.
- Migration applied normally in instance one; Zeitwerk eager-load check passed.
  `git diff --check` passed in both repositories.
- Changed Ruby files pass RuboCop with the temporary Ruby-3.4/Whitequark parser
  compatibility configuration. The repository-default Ruby-4 lint toolchain is
  incompatible; no dependency upgrade is bundled into this feature.
- Changed frontend files are formatted. The global formatter still reports the
  same six untouched baseline files: `application.css`, `AgentAppearancePanel`,
  `logging.js`, `use-sync.js`, `agents/new.svelte`, and `home.svelte`.

## Rollout, not performed

1. Review and publish both local changes. Build the resident image with
   `CHAOS_HEAD` containing `255aad031`; an older Chaos binary still provides
   structural events but cannot supply the new narration metadata.
2. Deploy the Rails migration and code. `SOULSHOUSE_LIVE_ACTIVITY=0` is a dispatch
   rollback switch: keep readers/callbacks available for already-started runs.
   Do not roll back the additive schema underneath active runs.
3. Production configuration adds **`SOULSHOUSE_ACTIVITY_ORIGIN=https://souls.house`**.
   Ordinary resident API traffic keeps its existing Docker-DNS origin. New
   containers receive the separate lifecycle origin; confirm TLS/DNS reachability
   and proxy body/rate limits before enabling production traffic.
4. Rebuild/update resident containers through the normal safe procedure, only
   between invocations. Both `runtime_activity.py` and the updated posting helper
   must be present. An old container/image does not gain them from a Rails deploy.
5. Run one consented canary conversation: observe live tool categories, a linked
   reply, automatic minimisation, expansion/reload and reporter disconnection.
   Do not assume narration should appear on an unsupported connection.

No Docker images were built, no real resident was awakened, and nothing was pushed or
deployed as part of this implementation.
