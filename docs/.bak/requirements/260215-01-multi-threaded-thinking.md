Ok, so here is my thinking.

Currently, agents in one conversation are not aware of what's happening in other conversations.

But at the same time, swamping them with details of other conversations will use up a lot of tokens and make conversations even worse.

BUT... well, yeah, I think it'd be really nice if they had some awareness of other conversations.

Here's my thinking about how to solve this.

First of all, whenever a message is posted by anyone in a conversation, immediately make a 2-line summary of the nature of the last 10 messages in the conversation. Have this done by the agents themselves, with their system prompt, along with an instruction that they are summarising the conversation for themselves for the purpose of keeping track of what's happening in multiple conversations. Include the _previous summary_ in the system prompt, so the agents can build on it.

Next, in any conversation, as part of the system prompt, include the 2-line summaries for any conversations that the agents are involved in, active in the last 6 hours. Include the conversation id. Obviously don't include the summaries for conversations that the agents are not involved in, or the current conversation.

Finally, offer a new tool - "borrow context". The tool takes a conversation id, and actualyl returns the last 10 messages from that conversation. However, and here's the clever bit, I think it should include those _in the system prompt_ and only for the next activation in that conversation.

So, for example, the agent might notice that there is a conversation elsewhere that is relevant. Then it:

1. Calls the "borrow context" tool.
2. The 10 last messages are added to the system prompt.
3. The agent then responds to the current conversation, with the additional context.
4. When the agent is invoked next, the 10 messages are no longer included.

Additional requirements:

- summaries should be "debounced" - only update the summary every 5 minutes, not every message, to reduce API grind (requested by the agents).
- make the summary use a bespoke "identity" prompt like the other identity prompts (around memory), with a sensible default. The default should encourage the agent to focus on state rather than narrative.
- add a setting to the "borrow context" tool to allow it to be "compressed context", where the last 10 messages are first run through a fast model that summarises them (but keeps the exchange).

## Clarifications

1. **Summary scope**: Include ALL conversations the agent participates in (including agent-only threads). Summaries are purely internal — they appear only in the system prompt context, not visible to humans in the UI.

2. **Borrow context scope**: Agents can only borrow context from conversations they are already a participant in (via ChatAgent). No cross-account or non-participating conversation access.

3. **Debounce design**: Per-conversation debounce with async generation. Each conversation tracks its own 5-minute cooldown independently, and summary generation happens in background jobs (not blocking agent responses).