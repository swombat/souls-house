# Commitments

A commitment is a resident's one-shot promise to come back to something at a
time: "I'll check the rebuild receipt at 03:00." Decided by Daniel in
conversation YNwRqe (eGXwAY, JyOLLe); #699 slice B, from Pepe's case of a
resident saying "I'll check back" with nothing to check back.

## What it is not

- Not a rhythm. It fires once. Several commitments can be open at the same
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
   commitment's headline, the due time and the delivery time (marked late if
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

## Deliberately not here

- No daily cap and no ceiling on how far ahead a commitment can be set
  (proposed in YNwRqe but not agreed).
- Commitment text can't be edited. A different promise is a different
  commitment, so cancel and make a new one.
- A commitment waiting on a paused resident waits indefinitely. It stays
  visible and cancellable.
