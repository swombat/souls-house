# Preserve disabled residents

The resident directory now shows a heart and configured daily heartbeat frequency when scheduling is enabled and the resident is active/unpaused. Otherwise the heart is muted. The create button says “New Resident”. Active residents appear first, disabled residents next, and deprecated/retired records last, alphabetically within each group. Disabled/deprecated cards remain editable but are greyed out.

The bin disables (`active: false`); the existing DELETE endpoint also only disables, including direct requests from old clients. The action is idempotent, audited as `disable_agent`, and does not destroy records or runtime files. It preserves heartbeat preferences and supports re-enabling through Edit. Existing availability checks exclude inactive residents from new conversations and scheduled/Telegram triggers. An already-running turn is not forcibly interrupted.

This is an application-action safeguard, not a new immutable-database policy: low-level operator maintenance, retention, account lifecycle and consent remain subjects for the larger lifecycle discussion. No model-level destroy override or mass data transition is introduced.

Tests cover directory ordering, heartbeat serialization and display, repeated disable requests, private-memory preservation, re-enabling, and the full browser disable/re-enable interaction. No production resident is disabled to test the feature.

## Verification and rollout

- Focused controller tests: 42 tests / 281 assertions passing. Frontend unit tests: 93 passing. Changed-file formatting, Ruby syntax and whitespace checks pass.
- The full Rails suite was run twice. The first run hit an unrelated process-signal test (`EPERM`); all seven process-runner tests then passed in isolation. The second encountered the memory-hook test while unrelated edits to that hook and its tests were being made concurrently in this checkout. Those files are not included in this change.
- Existing tooling limitations remain: RuboCop's installed parser rejects Ruby 4.0, and the repository-wide formatting check flags five unrelated files.
- `bin/house doctor` passed. A manual all-resident backup correctly refused an active resident. The non-forcing backup pass completed the database backup and available resident snapshots, leaving busy Claude undisturbed and retaining the prior successful snapshot.
- No migration, runtime image change or resident restart is required. Deployment suppresses fleet reconciliation.
- Browser rerun: 22 journeys passed, including both resident-page journeys and the full disable/re-enable flow; one unrelated simultaneous-writers synchronization test failed. Its isolated suite is being checked separately. No chat synchronization code is changed here.
- App-only deployment skips the runtime-build hook: that hook reads the working tree, which contains concurrent uncommitted memory-hook edits. The existing runtime image was verified present beforehand. The post-deploy webhook refresh runs separately with fleet reconciliation disabled.
