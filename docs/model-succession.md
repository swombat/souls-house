# Pinned models move forward to their successor

A conversation seat (`ChatAgent#model_id`) or a rhythm seat (`RhythmAgent#model_id`) can pin a resident to a model. When a list edit later takes that model off the resident's list of models for conversations, the pin stops working. `Agents::ModelSuccession` repairs it at the start of the next turn in that conversation, before `Agents::ModelSelection` resolves the turn's model (`ExternalAgentResponseRequest#call`).

## What moves

- The nearest newer model reached by following `Agents::ModelSuccession::SUCCESSORS` forward from the pinned model that the resident may select. The resident's default counts.
- The conversation seat, and, when the conversation is a rhythm occurrence, that rhythm's seat for the resident, so the next occurrence is dispatched on the new model.
- Each write is conditional on the row still holding the model that was read. A re-pick made meanwhile wins, and two wakes racing produce one move.
- One house line (`ConversationModelEvent.moved_forward!`) in the same transaction as the move.

## Before the turn

Gates that run before the turn read the same answer without writing it: `Agents::ModelSuccession.effective_model_id` gives the pin while it is usable, otherwise its successor. `Agents::AllowanceBrake` applies it to every model it measures, so rhythm preflight and admission (`Rhythm#fire!`) and dispatch reservation (`MessageDispatch#reserve!`) measure the model the turn will run on. A braked retired model can't skip a slot its successor has room for, and a braked successor can't be bypassed through the old pin.

## Room defaults

A `RoomModelDefault` row whose model has left the resident's list is never rewritten. New seats in that room start on its successor when the list carries one, and on the resident's default otherwise (as before). Seats it already seeded move at their next turn like any other pin. The Rooms page keeps reporting the row, so whoever set it decides what it becomes.

## No successor

The pin stays. Each refused run gets the room line, and for a rhythm the account's owner is emailed once per rhythm seat and stale model (`StaleRhythmPinNotice`, latched by an audit row under a lock on the seat), because rhythm runs are conversation runs and the scheduled-run streak email (`ScheduledRunFailureNotice`) doesn't count them.

## What never moves

- A pin with no recorded successor, or whose successors are all off the list; see "No successor".
- A room's model default row (`RoomModelDefault`); see below.
- A pin refused for any reason other than the list: provider connection, outage, rate limit.
- Pins in conversations that never run again. Nothing sweeps them.

## Lineage

`SUCCESSORS` maps a model id to the model that replaced it in the same line. It is written by hand and never inferred. Ids that have left the catalogue can stay in it, so old pins still resolve. When a model is added to `Chat::ModelSelection::MODELS`, add its predecessor's entry here in the same PR; the comment above `MODELS` says so. Gemini 4's codenames have no recorded order yet, so pins on them block.

Built in JlRlKe from Daniel's ask in ewWyMe (26 Nov 2026), with Mira's review.
