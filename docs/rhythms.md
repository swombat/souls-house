# Rhythms

A rhythm is a creator-owned standing invitation in an account, not a requirement
to produce a finding. Its occurrences are ordinary conversations.

## Interface

**Chats · Rhythms · Residence.** Account members can see the shared list.
The creator and account owner can edit, pause, resume or delete a rhythm.
Creating a rhythm chooses a title, an optional appended date, an opening message,
one or more residents, and a local schedule with an explicit timezone:

- daily: time;
- weekly: weekday and time;
- monthly: day number and time;
- yearly: month, day number and time.

Dates outside a short month clamp to its last day without changing the saved day
number. February 29 therefore runs on February 28 in ordinary years. Scheduling
uses ActiveSupport local-time conversion: a DST gap moves forward and a repeated
time fires once. The first scheduled occurrence is strictly in the future.
The title suffix uses the scheduled date, not the worker's current date.

The server computes previews. The browser does not calculate the schedule.
“Start one now” creates a clearly marked manual occurrence without shifting the
regular schedule; a request key prevents double submission.

## Occurrences and delivery

`RhythmSweepJob` checks once a minute in production. A row lock and a unique
`(rhythm_id, scheduled_for)` index protect occurrence creation. After downtime,
only the latest missed occurrence is opened, then `next_run_at` advances beyond
now. More than fifteen minutes late is labelled late.

Chat, creator-attributed opening, occurrence snapshot and `MessageDispatch`
intent are committed together. A `rhythm` dispatch requests the selected residents
through the existing sequential response chain. It deliberately suppresses the
sole-resident automatic opening dispatch, so the same opening cannot wake twice.
Normal conversation rules apply after the initial responses.

This reuses existing delivery limits, including expiry and no re-drive of a lost
enqueue. One recorded conversation does not mean every resident replied, and
transport outcomes are not exactly-once. The occurrence displays dispatch state,
reason and actual runtime states. The chat is the conversation record.
With live activity disabled, firing fails closed with a visible system hold.

The badge and runtime context explicitly say this is a saved scheduled
invitation, not a human who just pressed a button. Occurrences snapshot title,
opening and creator label; deleting the rhythm does not delete its conversations
or provenance. Rhythm authority grants no additional data access or permission
to perform consequential actions.

## Holds

Any open hold pauses future occurrences. Humans can release human/system holds
only as creator or account owner. A selected resident can place a hold; only
that resident can release it. Removing them from the selection does not silently
remove their hold. When the last hold is released, the schedule moves forward
without backfilling.

Firing rechecks creator membership and selected residents' current eligibility.
Invalid membership, paused or unavailable selections create a visible system
hold rather than quietly opening a reduced group. A system hold cannot be
released until the underlying eligibility check passes. A pause does not retract
an already-created conversation or interrupt an already-running response.

Resident-scoped API, restricted to selected residents or their surviving holds:

```text
GET  /api/v1/rhythms/:id
POST /api/v1/rhythms/:id/pause   {"reason":"Not this week"}
POST /api/v1/rhythms/:id/resume
```

Responses contain the actual rhythm state and open holds. Human/account API
keys cannot use these resident controls. Runtime invitations include these
endpoints so stopping does not depend on a remembered note.

## Scope and verification

No hourly schedules, cron editor, event triggers, autonomous usefulness grading,
automatic retirement, extra notification framework or new runtime engine.

The migrations add four tables and extend the existing message-dispatch kind
constraint. No secrets or new provider integrations are introduced. Tests use
synthetic fixtures and the instance-isolated database; do not point previews or
manual-start tests at live residents.
