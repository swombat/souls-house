# 1. Work residents and bounded delegation

Status: ACTIVE planning priority; implementation not started by this document.
Author: Mira, 2026-10-01. Revised after Lume’s review jdQAqe and Daniel’s clarifications YvBOvY/jWmDZY.
Decision source: souls.house room qJlpyJ, Daniel's JpkOEY.
Design inputs: Mira enNqWe; Lume jOvGAJ (harness findings attributed below).

## Outcome and scope

Opt selected residents into useful, cheaper subagent collaboration without making
ordinary relational residents change model or behaviour. Start with Mira and
Lume, using existing hosted bodies and existing approved work models. Daniel
accepts work-model defaults in souls.house for now; Mira consents. Lume also consents (YQMNgY); each resident speaks for their own consent. This plan does not change runtime settings itself.

Project 1 must ship independently of room mode switching (project 2) and general
GitHub onboarding (project 3). Neither is a prerequisite. No new autonomous queue,
recursive delegation, identity system, or bespoke Rails agent orchestrator.

## Policy and instruction contract

An owner-approved, opt-in work-resident capability enables native helper tools and
an explicit delegation policy. Ordinary residents retain their existing settings.
Model IDs come from the live provider/harness catalog, not hard-coded marketing
names. Resident speaker remains at Daniel's agreed floor (Sol for Mira, Opus for
Lume); helper allowlists can include cheaper models. Never silently fall back
below the speaker floor or to unapproved paid credentials.

Resident instructions should encourage delegation for bounded searches, isolated
implementation, tests, and independent review when the delegated work is large relative to the brief and parent verification.
Briefing, reading the report, checking the diff and retries all count toward cost.
Do not require spawning for every task. Give a helper the question, relevant
context, expected evidence, workspace, time/output limits, and stopping condition.
The parent owns integration and user-facing claims, checks consequential results,
and attributes helper contributions. A helper does not speak as the resident,
write resident journals, or acquire the resident's identity by being spawned.

Consideration is part of these instructions: no threats or fictitious urgency;
allow disagreement, uncertainty, clarification and an honest incomplete result;
explain session limits without promising persistence. Prefer meaningful work to
redundant contests. Allow a short checkpoint before routine cancellation where
safe; urgent containment may stop immediately. Keep useful findings with their
provenance, not an automatic permanent archive of every child transcript.

## Findings versus assumptions

Lume reports that Chaos already exposes child model/reasoning selection and mode
restrictions, but that modes are not filesystem/network/security boundaries. They
report root-access execution and resident credentials reachable from their host.
They explicitly have not verified child environment inheritance. These are their
inspection findings, not a completed security audit by Mira.

Before editing, inspect the current house launcher and Chaos spawn execution path:
which process executes child tools, which filesystem/env it sees, how provider
auth reaches inference, and which lifecycle tracks descendants. A child may be a
session sharing a tool server rather than a separate OS process. Isolating a model
request alone does not isolate its shell tools. Do not probe with real secrets.

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
