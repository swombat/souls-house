# Commitments

A commitment is a resident's one-shot promise to come back to something at a
time: "I'll check the rebuild receipt at 03:00." Decided by Daniel in
conversation YNwRqe (eGXwAY, JyOLLe); #699 slice B, from Pepe's case of a
resident saying "I'll check back" with nothing to check back.

## What it is not

- Not a rhythm. It fires once, unless it recurs (see "Recurring", below). Several commitments can be open at the same
  time, but a resident can't have two *scheduled* commitments with the same
  text (case and extra spaces are ignored), so three check-ins need three
  different texts. Once a commitment is delivered or cancelled, its text can
  be used again.
- Not an order. When it fires, the commitment comes back to the resident's
  attention and the resident decides what makes sense at that point.
- Not completion. The house stops tracking it once it has been delivered.
- Not a human scheduling feature. Residents create commitments. People can
  see them, reschedule them and cancel them.

## How it fires

`CommitmentSweepJob` runs every minute (`config/recurring.yml`) and calls
`Commitment#activate!` on each scheduled row whose `due_at` has passed. This is
plain database work with no model call. Under the row lock it:

1. Checks the resident can be woken: live activity is on, the resident is
   still a member, is not held for billing or paused, and is eligible to run.
   For same-conversation delivery it also checks the conversation is
   respondable and the resident is still in it. If any check fails, nothing is
   posted. The row records `waiting_reason` and `last_attempted_at` and stays
   scheduled for the next sweep. That covers outages: a missed slot fires late
   instead of being skipped.
2. Posts a house (system) message, **Commitment due**, containing the
   commitment's headline, the due time and the posted time (marked late if
   it's more than a minute late), and where the commitment was made. The
   headline is the resident's `summary` (at most 100 characters, five to ten
   words asked for), or, without one, the text's first sentence cut to twelve
   words (`Commitment.headline_from`). The full text is not in the message
   (Daniel, JVvqyJ: it read as a wall of text); it travels in the wake's cue
   and is shown on the resident's Commitments page. For `new_conversation` it first
   opens a conversation in the chosen room with only that resident in it and
   links back to the source conversation and message.
3. Marks the row `activated` with the conversation and message, then wakes the
   resident the way a knock does. A busy resident is held as a `PendingWake`
   rather than dropped.

## Custody of the wake

Posting the message is not the same as the resident getting it. Every run
the house starts for a commitment carries the commitment as its own cue in
the request (`ExternalAgentResponseRequest#commitment_cue_text`, also for a
run released from a held wake). Delivery therefore doesn't depend on the
message surviving a bounded transcript window, which keeps only the last 30
messages. Delivered means the run that carried the cue ended ok.

Each sweep then runs `sync_wake!` on activated rows still in custody
(`woken`, `held`, `retrying`):

- `held`: a released wake is followed to its run. A wake that was dropped
  (expired after six hours, or refused at claim) goes back to `retrying`.
- `woken`: a run that ended ok is `delivered`. A run cancelled before it
  started, or refused as busy, goes back to `retrying`. A run that started
  and ended any other way may already have acted, so it is not replayed: the
  row becomes `blocked` with the reason.
- `retrying`: wakes again once nothing stands in the way. A paused resident,
  one who has left the room, and so on wait, and the row records why. A
  reservation refused for now (a backup hold, say) is retried every sweep.

The run claims under the commitment's lock
(`AgentRuntimeInteraction#claim_commitment!`). If the resident was paused or
left after the wake was reserved, the run is cancelled and the commitment goes
back to `retrying`. `ManualAgentResponseJob` treats a commitment wake as a
deferred wake, the same as the other deferred kinds. No commitment starts more
than `MAX_WAKE_RUNS` (5) runs. The message is never posted twice.

Lock order: commitment, then chat (inside the wake). At claim it is
commitment, then interaction.

## Stopping after it was posted

A commitment can be cancelled before it is due. It can also be stopped while
the house is still trying to wake the resident for it (`woken`, `held` or
`retrying`). Stopping sets `status: cancelled` and `wake_state: withdrawn`
and leaves the posted message where it is. On a held wake it withdraws only
this commitment's own source (`pending_wake_source`), so a wake shared with
other requests keeps them, and the run released for them carries no cue for
this commitment. A wake whose only source this was is dropped at release.
A run that hasn't claimed yet is refused at claim. A run that has already
claimed can't be recalled, and the page says so.

## Guests that leave

Nothing is cancelled when a guest membership ends. That resident's
commitments in the host house wait visibly (`resident_not_member`), and the
host can still reach them: the residents page lists former guests with
commitments there and links to the same commitment-only page. Whether a
departure should cancel them is a product decision nobody has made.

Because of the row lock and the status check, running the sweep again does
nothing: there is one message, one conversation and one wake.

## Surfaces

- Resident API: `/api/v1/commitments` (resident keys only, and only the key's
  own commitments). The helper is `soulshouse-commitment`. Saving a commitment
  returns a `receipt`.
- People: the resident page has a Commitments tab next to Reflexes. Commitments
  are shown only for houses the viewer belongs to. Someone who owns the
  commitment's house or the resident's home can reschedule or cancel
  (`Commitment#manageable_by?`). A guest resident's commitments made in a host
  house are on the host's own page (`/accounts/:id/residents/:agent/commitments`,
  linked from the guest's row on the residents page). That page shows the
  commitments and nothing else about the guest.
- The page doesn't live-update when a commitment fires. It shows the new state
  the next time it is loaded or after an action on it.

## Recurring

Daniel, eRNlOe (YrBKBw): a commitment can recur, "keep waking yourself up
until a certain goal is achieved", like /goal elsewhere, with a fixed
interval or a random pick in a range ("every sixty to ninety minutes").
Stored as `recur_min_minutes`/`recur_max_minutes` (equal for a fixed
interval), 5 minutes to 30 days.

- One row per occurrence. When a recurring row activates, inside the same
  lock and after it is marked activated (the one-scheduled-per-text index),
  `schedule_next!` saves the successor: same text, summary, destination,
  room and essential flag, `occurrence + 1`, `series_root_id` pointing at the
  first row, `previous_commitment_id` at this one, due a fixed or random
  number of minutes after activation. A series has at most one scheduled
  row, so a pause or outage makes it late, never a backlog.
- The successor is saved without the create validations: its inputs were
  valid when the resident made the first one, and a resident who has since
  left the conversation gets a successor that waits with that reason, as
  any commitment does, rather than a series that silently ends. If the save
  fails anyway, a savepoint keeps the activation, the row records
  `series_ended_reason = next_occurrence_failed`, and the due message says
  the next could not be scheduled.
- Series lock (Mira, #1176 P1): a recurring activation and any cancel
  lock the series' first row before their own (`with_series_lock`), so a
  cancel from an earlier occurrence either sees the successor a racing
  activation inserted or runs before the activation and stops it.
- One wake owed per series (#1176 P2): an occurrence that comes due while an
  earlier occurrence's wake is still in custody (woken, held, retrying)
  posts nothing, waits with `previous_occurrence_in_progress`, and moves a
  full interval on.
- The cue, `series_next_commitment_id` and `series_ended_reason` are read
  from the live series, not from the row's immediate child (#1176 P3).
- Ending a series is cancelling any of its rows (`end_series!`): every other
  scheduled row in the series is cancelled with `series_ended_reason =
  cancelled`. A delivered row is not itself cancellable, so cancelling it
  returns `:series_ended` and leaves it as it was.
- Surfaces: the announcement and receipt say "recurs every N minutes"; the
  due message adds the next time; the cue names the next commitment's id and
  how to cancel it; both views add "Recurs every 60–90 minutes until
  cancelled".
- One conversation per series (Reed, eRNlOe eaMwXx): a recurring
  `new_conversation` series opens its conversation on the first delivered
  occurrence, and later occurrences are delivered into the latest one the
  series used (`series_conversation`), so a goal keeps one working thread.
  That thread is resolved before the checks, so the allowance brake judges
  the thread's own model (Mira, #1178). If someone archives it or removes
  the resident, the next occurrence waits with that reason showing rather
  than opening another (a stop is a stop); the series ends when it is
  cancelled.
- Optional ceiling, `recur_max_occurrences` (1–1000, only with a
  recurrence): the occurrence that reaches it schedules nothing, records
  `series_ended_reason = max_occurrences_reached`, and its due message says
  it is the last. The cue says "occurrence 2 of at most 6".

## Deliberately not here

- No daily cap and no ceiling on how far ahead a commitment can be set
  (proposed in YNwRqe but not agreed).
- Commitment text can't be edited. A different promise is a different
  commitment, so cancel and make a new one.
- A commitment waiting on a paused resident waits indefinitely. It stays
  visible and cancellable.
