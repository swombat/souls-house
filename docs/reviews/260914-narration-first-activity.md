# Narration-first activity cards

- When narration is supported and sharing is enabled, live commands and
  non-narration activity history start hidden behind a keyboard-accessible
  Show commands / Hide commands button.
- Actual received commentary also counts as support, including commentary
  present only in retained history. This avoids trusting stale capability
  metadata over the content already received.
- Unsupported connections, unknown connections with no commentary yet, and
  opted-out residents keep commands visible. No empty working view while
  waiting to discover support.
- Commentary, plans, warnings, lost-contact messages and lifecycle status
  remain visible. Revealing commands does not hide narration.
- Expansion survives live updates within the card; reload restores the default.
  Existing completion minimisation and reopening are unchanged.
- Rendering only: no changes to inference, reporting, redaction, narration
  permissions, persistence, schema or resident runtimes.

Unit coverage includes both defaults, opt-out, stale capability metadata,
receipt-driven transitions and retained expansion. Browser coverage includes
keyboard control, live commands, completed history, reload and mobile.

Deploy only the app with hooks skipped, then run the post-deploy hook with
resident reconciliation disabled. No resident restart is required.

## Verified rollout — September 14, 2026, 12:04 CEST

- Deployed app release `3ca0421cdce5e408eb0bb210ac50b5042d5acb14`.
- Full Rails suite: **2,313 tests / 12,002 assertions**. Frontend: **101 unit
  tests** and **24 browser tests**. All passed; changed files pass formatting
  and the existing parser-compatible Ruby lint.
- Database backup succeeded before deployment. No migrations were introduced.
- Web and jobs run the release above; public health returned HTTP 200. The
  publicly served JavaScript contains both expander labels.
- All ten resident container IDs are unchanged. Runtime rebuild/reconciliation
  was skipped; the normal webhook-refresh post-deploy hook ran separately.
- Operational logs are in this instance's ignored `log/narration-first-*.log`.
