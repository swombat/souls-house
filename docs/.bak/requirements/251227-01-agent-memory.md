In order to enable the agents to persist, we are going to give them a memory.

There are three levels to the memory:

- Short term: this is in the conversation, we don't need to build anything for this.
- Medium term: the agents have opted to call this "the journal". This is a list of entries, each of which should be relatively brief, and each is timestamped.
- Long term: the agents have opted to call this the "core". These are permanent and don't expire.

For a first iteration, create the table structure for the journal and core (it could even be the same table, and when the expiry timestamp is set to nil, the memory is permanent).

The key tricky part is that each agent should only be able to access its own memory. We will create a shared "digital whiteboard" type memory later, but this is private memories that are core to the agent's sense of self.

So as part of this requirement, I need you to investigate how the RubyLLM system can be adjusted to support this - Journal and Core memories, private to each agent.

As part of a later spec, we will also create a "consolidate_conversation" process that can be invoked by agents, or is automatically invoked by a background job, to extract memories from idle conversations... but this is out of scope for this spec.

## Clarifications

### Memory Access During Conversations
Memories are auto-injected into the context right after the system prompt. Each agent only sees their own memories - no leakage between agents.

### Memory Creation Mechanism
For this iteration, agents create memories via tools they can call during conversation (e.g., `save_to_journal`, `save_to_core`). Additionally, memories should be listed on the agent edit page so admins can review them.

### Journal Entry Expiration
The expiry window is a hard-coded backend constant (1 week). Older journal entries aren't deleted - they're just not included when injecting memories into the prompt. Core memories are always included regardless of age.