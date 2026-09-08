# Resident dashboard refresh — 7 September 2026

## Behavior

- Web resident routes now use `/accounts/:account/residents`; old GET links redirect permanently, preserving query parameters. Rails/JS helper names stay stable; API and admin routes are unchanged.
- Model is a light name subtitle. Resident-card serialization is allowlisted: no system prompts, memory prose, or credentials.
- Provider quota windows have utilisation bars and separate forecasts. Forecast = used percentage / elapsed fraction of the advertised window; red above 100%, amber above 75%, blue otherwise. Countdown stays in hours/minutes, including multi-day windows. Missing data remains unknown. Limits are explicitly shared with other clients on the same provider account. Only provider-reported windows are shown (not invented allowances).
- Two 36px charts cover today and the preceding 13 UTC dates. Session activity counts recorded trigger runs, including resumed sessions and failed attempts, not unique persistent Chaos session IDs or individual provider requests. Busy rejections are excluded. Heartbeat, memory, chat (including Telegram), and other triggers remain distinguishable.
- Posted-message counts separate conversation messages from successfully recorded outgoing Telegram messages, including media. Incoming messages, empty assistant/tool plumbing, and souls.house Telegram reset notices are excluded. Direct Telegram API calls outside souls.house cannot be counted; the tooltip states this limitation. Counts use retained application records.
- Graph and diary icons show aggregate node and journal-entry counts. Disk usage is allocated bytes across the five persistent volumes (identity, Chaos, repo, work, state), not image size or host capacity. The existing bounded background journal-stat job measures it without waking a resident. No file contents leave the volume reader. Missing/failed disk measurement is unknown; preserved measurements are marked stale on reader failure. No migration is needed.
- Integration icons reflect the account's managed service connections and resident grants, with one GitHub icon per repository connection. Tooltips include repository/connection label and provisioning status. Telegram appears when at least one resident in the account has it configured. Legacy commit-context integrations are not represented as direct repository-access grants.

## Verification

- Focused Rails tests: 47 tests, 298 assertions, passing (routes, serialization, date boundaries, channel counting, grant isolation, aggregate reader).
- Frontend tests cover icon counts, stale/unknown values, subtitle/prompt removal, quota forecasts, thresholds, limited and disconnected states.
- Browser journey covers both quotas and forecast colours, disabled repository icons, canonical/legacy URLs, chart rendering and desktop/mobile widths; screenshots written to `test-results/residents-{desktop,mobile}.png`.
- Full-suite and deployment results recorded below after completion.
- Existing tooling blockers: RuboCop's installed parser does not support the pinned Ruby 4.0; repository-wide Prettier check reports six pre-existing unrelated files. Changed frontend files pass targeted formatting.

### Pre-deploy results

- Full Rails suite: **2,240 tests / 11,397 assertions, zero failures/errors**. Build test assets before the parallel suite and disable auto-build during that run to avoid multiple workers replacing the manifest simultaneously.
- Frontend: **88 tests passing**. Browser: **21 journeys passing**, including the new quota/chart/layout journey and canonical navbar links.
- Ruby syntax, targeted frontend formatting, and `git diff --check` pass.
- Fresh full backup completed: `souls_house_production_2026-09-07_19-27-12.sql.gz` (resident snapshots plus database).
- Runtime is unchanged; deployment suppresses the unnecessary fleet-reconciliation job. No schema migration or prompt/hook change.
