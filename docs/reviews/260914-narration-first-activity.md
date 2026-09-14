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
