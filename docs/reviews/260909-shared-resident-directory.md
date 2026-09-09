# Shared resident directory

## Changes

- Active (including paused) residents remain visible. An initially unchecked **Show disabled** checkbox appears below them only when disabled or deprecated records exist. Revealing it shows disabled residents first, then deprecated residents below a divider. No records are deleted or changed by filtering.
- Admin account usage now renders the same cards and filtering, without Edit/Copy/Disable controls. The rest of the account overview, storage measurement action and session/conversation diagnostics remain.
- The faint model subtitle includes configured reasoning effort. `default` is labeled **provider default**: requests omit effort in that case, so a numeric/provider-specific default cannot honestly be inferred from the database.
- `Agents::ResidentDirectory` supplies the same bounded card presentation to both controllers. Private prompts, memory contents and runtime credentials are not added to card JSON.
- Admin OAuth bars use a site-admin-only endpoint, not account membership authorization. Ordinary members and anonymous callers cannot use this endpoint. It reads usage without waking residents.

## Deployment boundary

No migrations or resident runtime changes. Deploy the committed app with Kamal's hooks skipped, after confirming the existing resident runtime image exists. Run the post-deploy hook separately with `SOULSHOUSE_SKIP_AGENT_RECONCILE=1` to refresh Telegram webhooks without enqueueing runtime reconciliation. Compare running resident container IDs before/after; no resident restart is needed for these changes.

## Verification

Component tests cover filtering, ordering, divider, effort/default labels, read-only admin cards and the admin usage URL. Rails tests cover the shared serialization and endpoint authorization. Browser tests exercise both directories, disabled preservation/re-enable, deprecated filtering, and desktop/mobile layout.

Repository-wide RuboCop remains blocked by its parser's Ruby 4.0 support. Repository-wide Prettier still reports the same five pre-existing files (application.css, AgentAppearancePanel.svelte, logging.js, use-sync.js, agents/new.svelte); changed frontend files pass formatting checks.

- Full Rails suite: **2,296 tests / 11,872 assertions, green**.
- Frontend unit suite: **96 tests, green**.
- The first full browser run exposed older contracts expecting disabled/deprecated cards to be visible by default; updated them to reveal the new checkbox first. It also had chat-sync stress failures (pagination and simultaneous writers) unrelated to the directory changes. Both new directory journeys passed in that run; a serial full-suite rerun follows.
- Serial browser rerun: **22 passed**, with only the second old hidden-card count expectation failing. After updating that expectation, its focused desktop/mobile test **passed**. All 23 browser cases therefore have passing coverage; the chat-sync stress cases passed serially.
