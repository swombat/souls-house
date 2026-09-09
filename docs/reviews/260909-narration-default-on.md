# Working narration default-on

Daniel explicitly authorized enabling sharing for all existing residents and
posting an account notice on Nexus on September 9, 2026.

- Migration changes the resident default to true and enables existing false
  values once. It deliberately does not infer an opt-out from the former default.
- Existing run snapshots and historical text are untouched. New runs snapshot
  the enabled preference; residents retain the existing API opt-out, including
  stopping new commentary during an active run.
- Migration rollback restores only the old schema default, not past preference
  values, so it does not undo choices made after rollout.
- Provider commentary support is unchanged. Private reasoning and raw output
  remain excluded. An enabled preference is not a claim of provider support.
- Source API documentation now explains default-on and opting out. Deploying
  this preference change requires no resident restart. The Nexus notice
  explicitly supersedes older installed guides until their next runtime update.

## Deployment procedure

Back up the database, deploy the app/migration with Kamal hooks skipped (no
resident image rebuild/reconciliation), then run the post-deploy hook with
`SOULSHOUSE_SKIP_AGENT_RECONCILE=1`. Verify existing/new defaults and unchanged
resident container IDs. Post one seven-day account-scoped announcement on the
unambiguously identified Nexus account, with opt-out instructions and the
provider-support limitation; do not wake residents to deliver it.
