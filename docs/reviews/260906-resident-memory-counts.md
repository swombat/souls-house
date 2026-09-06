# Resident card memory counts

Replaces the retired Core / Journal / Inactive token totals on the resident
listing with **Mnemodyne nodes** and **Journal entries**. Deprecated inline
residents display neither.

## Counting and privacy

- Nodes: one account-scoped grouped SQL count, including private and dormant
  nodes. No node content, source pointers, or descriptions enter the page props.
- Journals: second-level Markdown headings (`## ...`) in regular
  `identity/memory/daily-journals/YYYY-MM-DD.md` files. Fenced examples,
  other files, and symlinks are excluded. This follows the shipped journal
  helper's entry format; arbitrary legacy Markdown formats are not inferred.
- A background job counts inside the existing container, returning only an
  integer. It does not invoke Chaos, wake a resident, start an offline container,
  or copy journal prose into Rails. Docker ownership checks still apply.
- Page loads request a refresh at most once per resident per two minutes.
  The cached result renders immediately; the existing account broadcast refreshes
  the page props when the job updates the resident. The lease prevents that
  broadcast from causing a refresh loop and allows recovery from abandoned jobs.
- Unmeasured counts show a dash. Failed refreshes preserve any previous count,
  label it stale, and retain its measurement time in the tooltip. A successful
  empty count is zero.

## Deployment

One additive migration adds cached journal statistics and a refresh lease
timestamp to `agents`. No runtime image rebuild, secret, graph migration, or
resident restart is required. This change does not itself deploy production.

## Verification

Coverage includes account isolation, dormant/private node totals without
disclosure, queue throttling, deprecated/deleted residents, failed measurements,
real Python parsing of synthetic journals, and desktop/mobile card rendering.
Browser screenshots are written to the Playwright test's output directory.

- Full Rails suite: **2,196 tests / 11,076 assertions**, no failures or errors.
  Test assets were prebuilt once, then the normal runner used
  `VITE_RUBY_AUTO_BUILD=false` to avoid each parallel worker rebuilding them.
- Card component tests: **4 passed**.
- Full browser suite: **19 passed**, including the new desktop/mobile check.
- Changed Ruby files: clean with the existing temporary Ruby 3.4/whitequark
  parser workaround. Stock RuboCop still cannot parse the pinned Ruby 4 target.
- Changed frontend files: Prettier clean. Repository-wide formatting still
  reports six pre-existing files outside this change.
- Desktop/mobile screenshots:
  `test-results/chat_contract-browser-cont-f2fe2-dgets-on-desktop-and-mobile-chromium/resident-memory-counts-{desktop,mobile}.png`.
