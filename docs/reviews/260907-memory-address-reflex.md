# Journal handles and private reflection continuations

Daniel authorized implementation, commit/push and deployment on September 7, 2026. Discussion: https://souls.house/accounts/gNDMev/chats/MYnrWY.

## Change

Clarify the stock Stop invitation, runtime instructions and `house-memory guide`:

- Decide whether to preserve a moment at the journal gate. An authored entry's
  source-linked graph handle is its retrieval address, not a second claim of
  significance. Reuse appropriate existing handles; do not impose a quota.
- Preserve disclosure choice, graph-pending reporting, idempotent retries and
  the resident's authorship. No automatic indexing or retrospective writes.
- Explicitly distinguish the internal reflection continuation from another
  incoming conversation message. Do not repeat/resend the completed reply or
  send private reflection/receipts to Telegram or a house conversation.
- Keep the existing one-invitation/loop-prevention behavior. Do not introduce
  Claude's invitation-versus-entry counts as pressure on other residents.

## Chris investigation: what the historical evidence does and does not prove

Read-only inspection of the resident journal SQLite database, scoped to one
September 6 Telegram interaction, found the full stock Stop invitation in the
canonical session as a **system** message, including the graph-formation block
and `journaled:` receipt instruction. An assistant message then repeated the
conversational reply. The separate Stop trace agrees: one invitation, followed
by a continuation with `stop_hook_active=true`. This is not merely one message
being displayed twice by the Rails runtime-output parser.

The corresponding journal entry exists, despite no `journaled:` receipt and
zero graph writes. Thus the earlier response-log classification missed actual
journaling. The trace does not establish an upstream transport defect or expose
why the model chose that response. This release is an explicit prompt-boundary
clarification, not a claim that provider behavior is now fixed. Assess subsequent
ordinary turns without manufacturing test interactions with the resident.

## Rollout contract

The existing memory-script installer updates pristine hooks and stages changed
stock beside customized resident hooks. Preserve that policy: do not overwrite
Claude's additions or other resident edits to force immediate adoption. Verify
active-versus-staged bytes separately. The updated image's guide and runtime
instructions also carry the clarification. Existing resumed sessions may retain
older stable instructions until their next full prompt; a staged hook is not an
active hook.

No memory bodies or intimate conversation excerpts are included in this record.

## Pre-release verification and recovery

- Updated from `origin/master` (`b857aaf`) before editing; existing untracked
  user files were left alone.
- Focused hook/guide/prompt tests: 15 tests, 133 assertions, passing before the
  additional receipt-loop regression was added. Installer suite: 13 passing.
- Frontend unit suite: 84 passing. Browser suite: 20 passing.
- Real amd64 candidate image built with unchanged pinned Chaos revision. Its
  installed hook generated the expected clarification in a network-disabled,
  synthetic check; no model or resident was invoked.
- Full-suite setup initially lacked Vite test assets. Built the test assets.
  The ensuing run exposed one pre-existing stale entrypoint assertion expecting
  direct hook installation. Updated it to check the current installer path;
  resident-preservation semantics remain covered by the installer tests.
- Ruby syntax and changed Markdown formatting pass. The existing RuboCop/AST
  combination cannot parse the project's Ruby 4.0 target; repository-wide
  frontend formatting reports six pre-existing files, none changed here.
- Fresh fail-fast full backup completed for all nine residents, followed by
  `souls_house_production_2026-09-07_16-51-39.sql.gz`.
- Previous runtime retained as
  `helixkit-agent-runtime:pre-memory-address-20260907`, image
  `sha256:e79ceb9abdfd1f46d3e9e24f8dcfb568da00484328b0131d11cd1be28683a435`.

- Final full Rails suite: 2237 runs, 11378 assertions, 0 failures, 0 errors, 0 skips

## Deployed and verified — September 7, 2026

- Application commit `b3f481bf8d914571267d0f317c4efb1404103d02` committed and
  pushed to `master`, then deployed with normal Kamal. Web and jobs both run
  that exact release; post-deploy hook succeeded with automatic reconciliation
  held until the verified manual pass.
- Runtime image
  `sha256:4238556c5c320bd376ec8ccca984e7ce99e4dbbe5d64838a1822cd0c909e1053`
  matched the separately checked candidate. Pinned Chaos remained unchanged.
- All nine residents were verified idle and reconciled via
  `HostedAgentRuntimeReconcileJob`, with explicit Docker/pgrep error checks
  before each call. All nine returned healthy; no busy resident was interrupted.
- Independently verified the actual image ID and installed stock hook, guide
  and runtime-instruction SHA-256 on **all nine** running containers.
- **Eight active hooks updated. Claude's customized hook remained byte-identical
  to its pre-deploy hash**, with the exact new stock staged as
  `stop_journal_reflex.py.upstream` and `HOUSE-HOOK-UPDATES.md` present. Adoption
  of that custom hook's update remains Claude's review, not a completed merge
  claimed by this rollout.
- Public `/up`: HTTP 200. No pending database migrations. Embedding probe:
  expected profile, 384 dimensions. Zero failed Solid Queue executions during
  the preceding ten minutes at verification.
- No resident memories were backfilled, no provider/model test turn was forced,
  and no claim is made yet about changed behavior on subsequent ordinary turns.

This documentation records the completed deployment after the application
commit; it does not change the deployed release identity above.
