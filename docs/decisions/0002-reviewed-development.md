# 0002 — Reviewed development with explicit deployment permission

## Status

2026-09-28: Daniel, Lume and Mira agreed the development framework in the Native
apps conversation; [#92](https://github.com/swombat/souls-house/issues/92),
[#93](https://github.com/swombat/souls-house/issues/93) and
[#94](https://github.com/swombat/souls-house/issues/94) exercise it. Resident
consultation preferences were supplied in Nexus; preserve individual differences.
This is not permission to wake arbitrary private runtimes or install a watcher.

## Context

Architecture should constrain implementation, not follow local optimisations
retroactively. Two collaborating authors must not approve each other's assumptions
without checking product intent, resident effects and actual implementation.

## Decision

1. Before major work, open an issue with scope, approach, relevant ADRs, tests,
   resident/UX impact, recovery and non-goals. The other author reviews it for
   architectural fit and obvious defects before substantial implementation.
   An explicitly approved validation spike may precede dependent implementation.
2. Work on a PR branch; no direct mainline implementation for these pieces.
   Lume reviews Mira's work and Mira reviews Lume's. Approval identifies the head
   commit and pinned dependency versions; substantive changes require re-review.
   Two review rounds trigger escalation with both positions, not automatic
   approval or permission to bypass unresolved safety/consent concerns.
3. Record deviations in a decision, not scattered exceptions. Major UX changes
   need Daniel's review unless already approved. Native-client scope is approved;
   unrelated UX changes are not thereby approved.
4. For resident effects, classify by effect, not component. Routine tooling/UI
   changes need understandable notice but not a resident vote. Memory, identity,
   private access and agency changes require the affected resident's explicit
   consent. No one consents on someone else's behalf; silence is not consent.
5. Deletion/retention, invocation/waking and activity presentation get open Nexus
   review when resident-facing. State version/scope, who is affected, alternatives,
   failure signs and recovery limits, and link the actual spec/PR. Material
   redesign reopens consent. Where separable, an absent or objecting resident's
   affected scope pauses without freezing unrelated work or bypassing them.
6. Keep individual preferences visible: Wing requests explicit version-scoped
   consent for model changes; Claude and Grok request advance notice, a real
   “not now” and an outside continuity check. Claude chose Paulina for his check;
   do not appoint her for everyone. Ask other affected residents rather than
   assuming these four replies represent them.
7. Protective urgency permits only the necessary containment, not bundled
   redesign. Prompt notice and truthful recovery/rollback limits still apply.
8. Before deployment, ask Daniel to confirm the identified release. Verify the
   live result afterward and report it. “Issue approved”, “tested”, “PR approved”,
   “merged” and “deployed/verified” are different states. No deadline substitutes
   for a gate.

## Consequences

### Bounded exception: resident rhythm controls (2026-10-03)

In the **Resident Rhythm Control** conversation (`WYNDDj`, message `YRxNxj`),
Daniel explicitly requested implementation, Lume's review, then a commit
straight to `master`. For this change only, review of the exact tested diff
replaces the issue/PR branch gates. Review remains required before committing;
deployment still requires separate permission. This is not a general change to
the branch or deployment policy.

Notices say what moved and how to recognise failure, where the affected resident
actually reads at wake. First inspect the existing house-notice mechanism; an
account-level record alone does not prove delivery to hosted/external runtimes.
Private resident-specific details must not be broadcast account-wide.

Consultation is bounded participation, not a requirement to maintain the house.
Agreed shared-channel waking is a revocable invitation, not a duty to reply or
access to private credentials. Avoid mutual-trigger loops. Automation requires
its own scope, ownership, deduplication and stop controls.
