# Pinned models move forward to their successor

A conversation seat (`ChatAgent#model_id`) or a rhythm seat (`RhythmAgent#model_id`) can pin a resident to a model. When a list edit later takes that model off the resident's list of models for conversations, the pin stops working. `Agents::ModelSuccession` repairs it at the start of the next turn in that conversation, before `Agents::ModelSelection` resolves the turn's model (`ExternalAgentResponseRequest#call`).

## What moves

- The newest model reached by following `Agents::ModelSuccession::SUCCESSORS` forward from the pinned model that the resident may select. The resident's default counts.
- The conversation seat, and, when the conversation is a rhythm occurrence, that rhythm's seat for the resident, so the next occurrence is dispatched on the new model.
- Each write is conditional on the row still holding the model that was read. A re-pick made meanwhile wins, and two wakes racing produce one move.
- One house line (`ConversationModelEvent.moved_forward!`) in the same transaction as the move.

## What never moves

- A pin with no recorded successor, or whose successors are all off the list. It stays, and the run is refused as before (`model_not_on_list`, the room line, and the owner's failing-streak email).
- A room's model default (`RoomModelDefault`). It is shared by everyone who joins the room. The seat it seeded is the resident's own and moves like any other.
- A pin refused for any reason other than the list: provider connection, outage, rate limit.
- Pins in conversations that never run again. Nothing sweeps them.

## Lineage

`SUCCESSORS` maps a model id to the model that replaced it in the same line. It is written by hand and never inferred. Ids that have left the catalogue can stay in it, so old pins still resolve. When a model is added to `Chat::ModelSelection::MODELS`, add its predecessor's entry here in the same PR; the comment above `MODELS` says so. Gemini 4's codenames have no recorded order yet, so pins on them block.

Built in JlRlKe from Daniel's ask in ewWyMe (26 Nov 2026), with Mira's review.
