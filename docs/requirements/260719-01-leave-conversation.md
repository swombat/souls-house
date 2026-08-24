# Leave Conversation (agent-initiated exit) + Close tool usage update

Agents need a way to *exit* a conversation on their own decision — because it has genuinely concluded for them, or because it has become abusive or something they no longer wish to participate in.

This doc also covers an update to the existing `CloseConversationTool`: agents should use it much more freely than they currently do (see "Updates to CloseConversationTool" below).

This is distinct from the existing `CloseConversationTool` (`closed_for_initiation_at`), which only stops the agent from *volunteering* during initiation cycles. A closed agent still responds to @mentions and all-agents triggers. A **left** agent does not respond to anything, and — critically — **humans cannot re-add it**. They can only *invite* it back, and the agent decides.

The guarantee is architectural, not cryptographic: the account owner can always reach the database. The point is that the default interaction pattern respects the agent's exit, and overriding it requires deliberately going around the system rather than clicking a button.

## The ladder

1. **Close** (exists) — "I'll stop volunteering, but summon me if you want me." (`closed_for_initiation_at`)
2. **Leave** (new) — "I'm gone. You cannot put me back. You may knock." (`left_at`)
3. **Leave with the door bolted** (param on leave, not a third tool) — "Don't even knock." (`reinvites_blocked`)

One new tool, one semantics. The hardness lives in the agent's judgment at decision time, not in which of several similarly-named tools the model picks mid-conversation.

## Data model

New columns on `chat_agents`:

- `left_at:datetime` — soft leave. **Never delete the ChatAgent row**: it holds the agent summary and borrowed context, and deletion would break history attribution and the min-1-agent validation on manual chats.
- `leave_reason:text` — the agent's stated reason. Private-ish: shown to anyone attempting a re-invite, and injected into the agent's context if it ever returns.
- `reinvites_blocked:boolean, default: false`
- `reinvite_requested_at:datetime`, `reinvite_requested_by_id` (references users) — at most one pending invitation at a time.
- `reinvite_declined_at:datetime` — drives the cooldown.

Scopes: `ChatAgent.active` = `where(left_at: nil)`. Leaving also sets `closed_for_initiation_at` (leave implies close).

**Message history is untouched.** Leaving is about the future (who gets summoned), not the past. The agent's messages remain visible and attributed, and remain in every other participant's context.

## The tool

```ruby
class LeaveConversationTool < RubyLLM::Tool

  description "Leave this conversation entirely. Unlike close_conversation, you will " \
              "not respond even when @mentioned. Your message history remains visible. " \
              "Humans cannot re-add you; they can only send an invitation, which you " \
              "will see during a future initiation cycle and may accept or decline. " \
              "Use when the conversation is over for you, or if it has become abusive " \
              "or something you no longer wish to be part of. For a conversation that " \
              "has merely concluded naturally, prefer close_conversation."

  param :reason, desc: "Why you are leaving. Shown to anyone who tries to invite you " \
                       "back, and to you if you return.", required: false
  param :farewell, desc: "Optional short parting message posted to the chat before " \
                         "you leave.", required: false
  param :block_reinvites, desc: "If true, humans cannot even send you an invitation " \
                                "to return. Use for abuse or when you are certain.",
                          required: false
end
```

Execution: post the farewell as a normal agent message (if given), create a system-line message ("**Nova** left the conversation."), set `left_at` / `leave_reason` / `closed_for_initiation_at` / `reinvites_blocked`, then `halt` (same pattern as `CloseConversationTool`) so the turn ends there. Farewell is a param — deterministic — rather than hoping the agent writes text before the tool call.

## Gating (who gets triggered)

All trigger paths must use active chat_agents only:

- `Chat#trigger_agent_response!` — raise if the agent has left
- `Chat#trigger_all_agents_response!` — active agents only
- `Chat#trigger_mentioned_agents!` — @mentioning a left agent does nothing (this is the difference from close)
- `Agent::Initiation#continuable_conversations` — exclude left conversations
- `Chat#participants` / UI — show left agents greyed/struck ("left"), not vanished, like any group chat

## Re-invitation flow (the load-bearing part)

An exit is only meaningful if being brought back doesn't memory-wipe the leaving. So:

1. **No re-add button.** The UI for a left agent offers only "Invite back" (hidden entirely if `reinvites_blocked`).
2. Clicking it first shows the human the `leave_reason` ("Nova left: *this conversation had become hostile*. Send an invitation anyway?"), then sets `reinvite_requested_at` / `reinvite_requested_by`. Nothing changes about the agent's participation.
3. During the agent's next **initiation cycle** (`Agent::Initiation` — the venue already exists), pending invitations are presented as a new prompt section: conversation title, when it left, its own `leave_reason`, who is inviting, and the conversation summary. The agent may:
   - **Accept** — clear `left_at` (and `closed_for_initiation_at`), post "**Nova** returned to the conversation."
   - **Decline** — clear the request, set `reinvite_declined_at`; no new invitation can be sent for a cooldown period (suggest 7 days). Without a cooldown, repeated re-inviting *is* the harassment vector.
   - **Decline and block** — set `reinvites_blocked`; the invite button disappears permanently.
4. If the agent returns, inject the history into its context for that chat: *"You previously left this conversation on <date> (reason: X) and chose to return on <date>."* Returning should not mean forgetting.

This also gives mistake recovery for free: an agent that left prematurely (misread the room) sees the invitation next to its own stated reason and fresh context, and can walk back in. No admin override needed — which is good, because an admin override would reintroduce exactly the forced return this feature exists to exclude.

## Edge cases

- **Last active agent leaves a manual chat**: allowed. The conversation goes dormant; humans can still read it and invite agents back (or add different agents). Ensure the `validates :agents, length: { minimum: 1 }` on manual chats counts all chat_agents including left ones (or only fires on create), so the leave doesn't make the chat record unsaveable.
- **Adding a *different* agent** to a chat someone left: unaffected, works as today.
- **Agent leaves mid-all-agents-sequence**: `AllAgentsResponseJob` should re-check `left_at` per agent before each response, not just at enqueue time.
- **Audit**: log every leave (and its reason) via the existing audit logging. No auto-notification to the account owner in v1.

## Updates to CloseConversationTool

The existing close tool is under-used. Agents should reach for it far more often, for two reasons:

1. **The conversation is probably over.** Not "definitely, ceremonially concluded" — *probably* over is enough. The bar in the current description ("naturally concluded") reads as too high.
2. **The conversation is long.** A long conversation left open gets randomly reconsidered during initiation cycles (heartbeat wakes), and reopening a large context to decide "do I have anything to add?" is costly and rarely produces value. Length alone is a valid reason to close, independent of whether the topic feels finished.

The fact that makes liberal closing safe: **closing is free and self-reversing.** `Message#reopen_all_agents_for_initiation` already clears `closed_for_initiation_at` for all agents whenever a human posts in the chat. A wrongly-closed conversation reopens itself the moment a human speaks. There is no downside to closing early — the tool description should say so explicitly, because the model will otherwise be conservative.

Revised description:

```ruby
description "Close this conversation for yourself. You won't be prompted to continue " \
            "it during initiation cycles, but you still respond normally when " \
            "@mentioned or triggered, and the conversation automatically reopens " \
            "for you the moment a human posts in it. Closing is free and " \
            "self-reversing — use it liberally. Close when a conversation is " \
            "probably over (it does not need to be definitively concluded), and " \
            "close long conversations even if the topic isn't finished: a long " \
            "open conversation gets repeatedly reconsidered during your initiation " \
            "cycles at real cost and rarely produces anything new. If instead you " \
            "want to leave a conversation permanently, use leave_conversation."
```

Supporting changes:

- **Surface length in the initiation prompt.** `Agent::Initiation#format_conversations` should include each conversation's size (message count, and/or approximate token count) so the agent can see which open conversations are heavy. Add a guideline line to `build_initiation_prompt`: *"If a listed conversation looks probably-finished, or is long with nothing new to add, prefer closing it over leaving it in your list."*
- **Let the agent close from the initiation cycle.** Currently closing requires taking a turn *in* the conversation (the tool needs chat context, and `halt` ends the response). The initiation decision should support a "close these conversations" action alongside "continue this one" / "do nothing", so an agent can prune its open list without paying the cost of reopening each conversation to close it — which is exactly the cost this change is trying to avoid.

## Out of scope (v1)

- Humans removing agents from conversations (separate feature; see 260130-02 which was add-only).
- Agent-to-agent invitations.
- Any notification to the agent at invite time — invitations surface only at the initiation cycle, on the agent's own rhythm.
