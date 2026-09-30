I'd like to make it so that if a human agent interacting with the conversation mentions one of the agents by name so at the moment typically that's going to be Grok, Chris, Claude and Wing that the agents is automatically triggered to respond without the human having to press the button to trigger the agent to respond. ideally this would not be all the agents at the same time, but for them to be triggered in order with a similar system is when you click ask all except with just the agents that have been named and with you know doing them in turn so they don't all answer at the same time.

## Clarifications

1. **Scope**: Auto-triggering only applies to group chats (`manual_responses: true`). Single-agent chats already auto-respond and need no changes.
2. **Mention format**: Case-insensitive word matching. Typing the agent's name naturally in a message triggers them (e.g. "Hey Grok, what do you think?").
3. **Agent-to-agent**: Only human-authored messages trigger auto-responses. Agent messages mentioning other agents do NOT trigger them (prevents loops).
4. **Fallback**: If no agents are mentioned by name, behavior stays exactly as today - no auto-trigger, user clicks buttons manually.