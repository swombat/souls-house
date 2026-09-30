Let's give the agents the ability to initiate and/or continue conversations with the user.

Every hour, during daytime hours (9am-9pm GMT), for every active account that has agents, the system should run a job that itself spawns N other jobs, one for each agent.

For the respective agent, the job should first sleep for a random number of minutes between 1 and 20 (unique to each agent, so probably passed to the job - perhaps with `perform_in`) so the flow is more natural and agents aren't all running at the same time. Then it should use RubyLLM to ask the agent if it wants to initiate a conversation, or continue an existing conversation.

In order to make this decision, the agent should be given a system prompt that includes its identity and memories, and also a list of the most recent conversations that it's involved in and that it wasn't the last agent to respond to, with their summaries (I believe those are generated already). And of course it should include the agent's memories.

This should run in an agentic loop, with a tool allowing the agent to either fetch more details about the conversation (which would provide it with a JSON object with the last 10 messages in the conversation). Another tool should allow the agent to make its decision, whether to continue an existing conversation, or initiate a new one (specifying which other agents should be included in the new conversation, and the topic it wants to discuss and why that is important), or do nothing for now (logging a journal memory to say that it did nothing for now and why).

If the agent decides to continue an existing conversation, just use the normal flow to continue the conversation.

If the agent decides to initiate a new conversation, create the conversation object, invite the relevant agents, and let the agent post the first message, specifying in its initial system prompt that it is initiating the conversation, the topic it chose, and who it has invited to the conversation (human users are automatically part of every conversation). Then, after the agent has posted its first message, run the normal conversation flow for all the other agents in the conversation.

## Further details

The prompt asking the user to decide whether to start/continue a conversation should include the current time. The list of conversations should include the time of the last message in each conversation. Conversations more than 48 hours old since last message should be included in the list but with a note saying that it has been inactive for a while.

The "do you want to initiate a conversation?" prompt should also mention if any agents have initiated conversations recently (including the agent being asked), and how long ago this happened. The prompt might indicate that both individual agents and the group as a whole should probably not initiate too many conversations at once.

Also include, in the system prompt, the timestamp of the last message from each human participant in the account, so the AI knows who has been active recently.

Make sure every agent decision is logged in the audit log.

Include a hard cap - if the agent has initiated twice and there has been no response from any human user, it should not initiate until there is a response from a user somewhere. But it should still run the loop (though that may be painful).

In this initiation prompt, also include the last outreach of this specific agent, and whether there has been any response from a human user.

## Clarifications

1. **Active account definition**: Based on human activity - determined by last audit log event (showing user activity in the app) AND last message posted in the account.

2. **Hard cap scope**: Per agent. Each agent can initiate max 2 conversations without human response. Resets only when a human responds to a conversation started by that specific agent.

3. **Staggered execution**: Random each time (not consistent per agent) to give an organic feel.

4. **"Recently initiated"**: Within the last 48 hours.

5. **Data model**: Discover from existing codebase - agents, conversations, memories, summaries already exist.