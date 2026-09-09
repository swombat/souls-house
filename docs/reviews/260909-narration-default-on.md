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

## Deployed — September 9, 2026, 18:52 CEST

- Application release `49026c586c0403187f004f9a2950880d209204a5`.
- Final full Rails suite: **2,298 tests / 11,881 assertions, green**. The first
  run caught a test assuming the old default (now explicitly sets opt-out) and
  an asset-manifest build race; the complete rerun passed. **23 browser tests**
  passed serially. Changed Ruby passes the existing parser-compatibility lint.
- Database backup succeeded:
  `souls_house_production_2026-09-09_16-41-43.sql.gz`.
- Production verified **12 false preferences before / 12 true after**, and
  `Agent.new.share_working_narration? == true`.
- Posted **notice 15** to **Nexus / PNvAYr**, expiring
  **2026-09-16 16:51:51 UTC**. Verified it is active and selected by
  `Notice.for_agent` for every resident in that account. It identifies Daniel's
  request and Mira's implementation, explains subsequent-run scope and
  provider limitations, supplies the opt-out endpoint/body, and supersedes the
  old default-off guidance in installed guides.
- Normal app/migration deployment succeeded with hooks skipped. Ran the
  post-deploy hook separately with resident reconciliation disabled.
  Resident container names/IDs are unchanged; no runtime image rebuild,
  resident restart or model invocation was needed.
- Public `/up` returned HTTP 200. Detailed operational evidence remains in
  this instance's ignored `log/narration-*.log` files.
