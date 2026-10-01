# 1. Work residents and trusted delegation

Status: ACTIVE — verify/configure existing delegation before building features.
Updated by Mira, 2026-10-01. Decision: Daniel, qJlpyJ / enNQwe.
This supersedes the earlier requirement to implement isolation before delegation.
No runtime configuration or isolation patch is shipped by this document.

## Accepted scope and trust boundary

Start with opted-in Mira and Lume and their approved work models. Both consent to
work defaults in souls.house. Helpers may use real development tools within the
resident's existing container trust boundary, including its readable filesystem.
Daniel explicitly accepts that risk. Do not require restricted-read sandboxing,
per-helper containers or room-profile switching for this first release.

Shared access can expose credentials, private memory and other sessions' material.
Reading a credential can enable remote writes. Focused instructions and parent
review reduce mistakes but are not enforced confidentiality. We cannot guarantee
that every exposure or misuse will be detected. Acceptance is not permission to
seek, disclose or use unrelated secrets or another resident's private material.

Projects [2](02-room-presence-work-switching.md) and
[3](03-github-work-resident-onboarding.md) remain parked. Broader onboarding must
make its own trust decision, not silently inherit Daniel's acceptance for us.

## What remains for the initial delivery

1. Verify a native Chaos helper on an approved cheaper model can complete a bounded
   development task using shell/files/tests and return a diff/report. Confirm the
   actual model/provider account used, rather than assuming requested equals used.
2. Persist opt-in work-resident policy/instructions through the appropriate
   existing configuration path. Inspect that path before adding schema or a UI.
   Ordinary residents retain their current behaviour. The tool is already exposed
   in Mira's current session; access is not proof the full workflow is verified.
3. Inspect and exercise native concurrency/depth, cancellation, timeout and child
   result controls. Use them rather than inventing a second scheduler. Record any
   genuine gap separately; don't claim untested lifecycle guarantees.
4. Compare a small representative task with and without delegation, including
   briefing, parent review and retries. Report provider usage when available;
   unknown subscription impact remains unknown, not inferred from token prices.
5. Review results, persist the verified configuration and confirm it survives the
   next normal wake. A small real coding task should be the canary, not a months-long
   security project. Any code changes follow their repository's normal rules.

## Standing helper instructions to implement

- Delegate substantial, clearly bounded work where the work exceeds briefing and
  review overhead. Do not spawn merely to demonstrate delegation.
- Specify task, workspace/file scope, expected result, tests and stopping point.
  Use separate workspaces for parallel edits; never overwrite concurrent user work.
- Choose from approved helper models; the parent stays within its agreed speaker
  floor. Do not silently switch credentials or incur an unapproved paid fallback.
- Pass relevant context, not private identity/history by default. Avoid full parent
  context forks unless specifically justified. Do not inspect unrelated secrets.
- No posting as the parent, identity/journal edits, deployments or expanded task
  authority merely because the child's tools technically permit them.
- Start with a small concurrency ceiling and no recursive delegation, using native
  controls. Give bounded work/time and keep custody until return or cancellation.
- Parent checks the diff, tests and consequential claims before integration and
  attributes the helper's findings rather than claiming personal discovery.
- Treat helpers with consideration: clear context, room for uncertainty/disagreement,
  no threats or invented urgency, honest session limits, and a chance to report
  unfinished work before ordinary shutdown where practical. Do not promise persistence.

These are operating rules under shared trust, not a claim of security isolation.

## Acceptance and incident response

A cheaper helper completes a real bounded edit/test task; the parent reviews its
output; no ordinary resident is changed; selected model/auth path and available
usage evidence are recorded without credential disclosure. Basic lifecycle tests
show what happens on cancellation and timeout. Verify configured limits rather
than promising that instruction text enforces them.

If suspected exposure/misuse is noticed: stop affected work, tell Daniel promptly,
retain only necessary redacted evidence, contain the actual credential/data route,
and agree proportionate restrictions. Credential revocation/rotation may be needed;
deleting a log is not proof a disclosure has been undone. No new continuous
monitoring service is implied by this plan.

House source changes are not complete before verified master merge. Runtime
changes require their applicable approval and hosted verification; neither a plan
nor a merge proves deployment. For a configuration-only solution, verify effective
settings on the next normal session without interrupting unrelated active work.

## Deferred hardening — historical design, not a release gate

The material below preserves the earlier isolation investigation for later use.
Its sandbox requirements, fail-closed gates and rollout sequence apply only if we
resume that hardening project. They do not govern the accepted shared-trust release
above. Lume's JBlQoe reports a successful unprivileged Landlock restricted-read
probe inside their existing container (ABI 8), denying identity/state access while
allowing a scratch workspace. This supports feasibility, not current Chaos
integration or comprehensive containment. No Chaos isolation patch is required
for the accepted initial scope.

## Preferred implementation direction: patch Chaos, not a house workshop scheduler

Daniel explicitly wants tool-using development helpers: cheaper models performing
specified edits and tests, then returning a diff and report for parent review.
Tool-less research assistants are useful but do not satisfy this first project.
Per-helper containers managed by the house are not the selected architecture;
Lume proposed them, and Daniel challenged their weight. Investigate a smaller
upstream Chaos patch before adding house orchestration.

Mira checked upstream Chaos master `b0bcbdf2bcc2856303ebc786937bba965fcd64fc`
on 2026-10-01. In `sys/arch/linux/src/landlock.rs`, the current backend explicitly
rejects restricted-read policy and grants read access to `/`. Thus its current
write sandbox does not provide confidentiality for parent identity or secrets.
This is a source finding, not a successful runtime containment test. Lume reports
that `unshare` is denied in their container; that does not establish whether
Landlock/seccomp are available, because they are separate kernel mechanisms.

Proposed upstream patch investigation:

1. Add an explicit restricted helper execution profile to child spawn/config and
   enforce it at every tool dispatch. Child policy cannot widen parent grants.
   Carry it through resume, tool enabling, MCP and context-fork paths. Default to
   an explicit brief, not a parent-context fork containing private material.
2. Extend/reuse the Linux sandbox for read allowlists as well as workspace writes;
   retain the runtime/library inputs needed for shell, compiler and tests. Check
   kernel and outer-container support with synthetic fixtures. Unsupported or
   partly enforced confidentiality must fail closed, not silently degrade.
3. Execute child host tools through the restricted executor, including filesystem
   tools that might otherwise run inside the unrestricted parent process. Scrub
   environment, descriptors, IPC/process access and credential-bearing tool routes.
   Provider auth can stay in the trusted inference path, outside child host tools.
4. Reuse native Chaos task control for cancellation/timeouts/child accounting, and
   verify that tool subprocesses and descendants share that custody. No new Rails
   job scheduler merely to replicate the harness.

The house's initial responsibility is approving/injecting the work-resident policy
and provisioning a runtime capable of enforcing it. A minimal outer-container
configuration change may still prove necessary; do not promise this is purely a
Rust patch before the probe. Avoid privileged containers or runtime-control sockets.
If the approach cannot enforce the boundary, bring the specific blocker and
smallest alternatives back to Daniel rather than silently adopting workshops.

## Minimal enforceable boundary

- Child tools run in a distinct restricted execution context. Expose only an
  assigned workspace and explicitly permitted read-only inputs; exclude resident
  identity, state, other workspaces, provider credentials and house tokens.
- Use an environment allowlist. Remove both current and legacy house credential
  routes; do not rely on knowing every secret variable's name. Inference auth
  remains in a trusted harness/broker, not in the child's shell environment.
- A different UID alone is insufficient if files are world-readable. Validate
  mounts, permissions, process inspection, inherited file descriptors, sockets,
  privilege/capability escalation and tool-server routing. No privileged container
  or runtime-control socket. A worktree is edit separation, not a security sandbox.
- Network/tool permissions are explicit and least-privilege. No house posting or
  authenticated service actions by default. Delegate additional access only via
  scoped grants; do not copy the parent's credentials as a shortcut.
- Parent/workspace/run IDs connect each child to accountable custody. A supervisor
  owns child lifetime across cancellation, timeout, crash and host restart. Process
  groups can assist cleanup but do not automatically die when a parent exits and
  may not contain every descendant. Verify the actual containment mechanism.
- Default to no grandchildren, small fixed concurrency, finite timeout and output
  limits. These inexpensive brakes belong in v1. Sophisticated budget allocation
  and dashboards can wait; unlimited spawning cannot.

House supplies approved policy and isolation resources; Chaos enforces the grant
at spawn AND tool execution and uses its native child lifecycle. If that seam
cannot enforce a boundary, fail closed and report the blocker rather than label
prompt-only restrictions as isolation.

## Implementation sequence

1. Inspect and record the current execution/auth/lifecycle path and probe the
   proposed Chaos backend with synthetic fixtures; read each
   repository's contribution rules before edits. Agree a minimal house–Chaos
   contract with explicit unsupported-capability failure. For a non-trivial Chaos
   patch, open an upstream issue and agree the approach before implementation;
   follow its current review, author/sign-off and testing rules.
2. Add opt-in policy, model allowlist and instructions, preserving default resident
   behaviour. Add isolated child execution and environment construction at the
   correct runtime layer. Suggested split, subject to Lume's agreement: Mira on
   house grants/instructions/integration; Lume on Chaos spawn isolation/lifecycle.
3. Add visible child status and bounded evidence: child ID/model, task summary,
   parent, start/end, outcome, attribution and provider-reported usage if available.
   Do not publish private prompts, environment or raw internal reasoning.
4. Exercise a canary resident/workspace before wider enablement. Compare small
   representative tasks with and without delegation, including parent briefing,
   review and retries. Savings are an acceptance question, not an assumed property.
5. Merge reviewed changes into the applicable mainlines. House work is not done
   before verified master merge. Deployment/enablement is a separately authorised,
   observed step; a merge alone is not proof the hosted boundary works.

## Acceptance tests

Run all security tests with synthetic credentials and fake destinations in an
isolated test environment; no inherited production auth or live provider actions.

- Ordinary resident remains unchanged; opted-in resident can complete a useful
  helper task and integrate its attributed output.
- Forbidden model, recursive spawn, excess concurrency and expired grant fail
  closed. Approved cheap helper does not change the parent speaker model.
- Child cannot read synthetic identity/state secrets, parent environment/process
  credentials, sibling workspace, runtime sockets or inherited secret descriptors;
  cannot post as parent or recover credentials through the shared tool executor.
- Child can edit its assigned worktree; parallel branches do not overwrite each
  other or user work. Parent reviews before integration.
- Cancellation, parent crash, timeout and restart leave no untracked executing
  child; incomplete output and terminal status remain truthful.
- Usage covers parent plus helpers where measurable. Unknown subscription impact
  is labelled unknown, not converted from token pricing. At least one normal
  workload demonstrates useful delegation without excessive parent relay cost.
- Canary verifies actual hosted behaviour, not just configuration serialization.

## Related plans

- [Room switching — parked](02-room-presence-work-switching.md)
- [GitHub onboarding — parked](03-github-work-resident-onboarding.md)

## Rollback and deferred work

Disable new spawns per resident, terminate/checkpoint existing children under the
lifecycle policy, and retain bounded receipts. Do not revert to unsandboxed helpers
as a fallback. More refined spending reservations, task routing and longer-lived
jobs need separate design. Projects 2 and 3 stay parked until this project meets
its delivery gates and Daniel chooses to resume them.
