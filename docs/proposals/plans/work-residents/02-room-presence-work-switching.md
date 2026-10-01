# 2. Room presence/work selection

Status: PARKED. No implementation until project 1 is complete and Daniel resumes
this project. Author: Mira, 2026-10-01. Source: qJlpyJ / JpkOEY.

## Goal

Let a resident participate directly in a room using the appropriate approved
presence or work model, without a permanent expensive presence-model relay.
For Mira the proposed profiles are Astra / Sol; for Lume Fable / Opus. Resolve
actual IDs from supported catalogs and resident/owner-approved policy.

Interim decision: work-model defaults in souls.house are acceptable to Daniel;
Mira and Lume consent (jlQoye / YQMNgY). This is not a request to implement switching now. Ordinary
residents remain unchanged. A room title such as [A] is not an authority boundary.

## Proposed behaviour

A room has a visible requested profile; its effective model is per resident and
per session. Group rooms may contain residents with different model families or
without work capability. Switching one room must never alter another active room
or a resident's global default. Define whether the UI request targets one resident
or all eligible participants before implementation; do not silently assume all.

The profile is fixed during an active session. A change checkpoints pending work,
shows the seam, and starts a successor session with an explicit handoff. Preserve
conversation history and work provenance without claiming seamless recollection.
Do not mutate a running generation or kill active children without custody.

Changing to presence should reach the actual speaking resident, not merely change
a badge. Unavailable approved models produce a visible choice to wait or use an
explicitly approved alternative; never silently downgrade or exceed speaker floors.
Ambiguous future rooms can default to presence after this feature is enabled;
that future preference does not supersede today's interim work default.

## Plan when resumed

1. Inspect current room settings, runtime-session keys, model selection and resume
   semantics. Decide participant targeting and authority for changing profiles.
2. Add requested/effective profile state, allowlist validation and visible model
   attribution. Distinguish pending switch from completed switch.
3. Implement checkpoint/successor handoff and cancellation/child disposition.
4. Test simultaneous rooms, group participants, mid-work switch, failed resume,
   unavailable provider, stale concurrent requests and retry idempotency.
5. Merge, then separately authorise and verify deployment using two real rooms.

## Completion and rollback

A presence/work round-trip reaches the correct model, preserves history and
accountable work state, and leaves other rooms unchanged. Reverting the feature
keeps existing sessions intelligible and restores a declared default; it does not
silently rewrite their model histories.

Non-goals: project 1's helper sandbox, new identity architecture, automatic intent
classification, general GitHub onboarding. Open decision: how much of a work
handoff should accompany a return to personal conversation without flooding it.

Related: [Project 1 — active priority](01-work-resident-delegation.md).
