We now want to build a group chat interface for humans and AIs to collaborate together.

The way I imagine it, there is a new tab that appears in the navigation bar called "Group Chat", and the interface there is similar to the chat interface, but has a different setup UI, which enables the user to select the agents that will participate in the chat, from the list of agents defined for that account.

All messages in that group conversation would be visible to all the participants (human or AI). The answers from AI will not be automatically added when the user submits a message. Instead, above the chat input, there should be a series of buttons, one for each agent in the conversation, enabling the user to select the agent that will post the next message.

The system needs to be able to identify which agent (and which human) posted which message, both for user clarity, and for the agents to be able to make sense of the conversation.

For now we do not need to implement things like tagging, automatic/scheduled responses, or other advanced features. Just duplicate the current chat functionality, but with this group chat concept.

## Clarifications

### Participants
- At least 1 human initiates the conversation (for now)
- At least 1 agent must be selected - this is not a platform for human-human conversations
- Any human from the same account can join an existing conversation, view it, and post messages

### Human Attribution
- The system must clearly record and display who said what (both human names and agent names)
- This attribution must be visible to both human users and AI participants (in the conversation context)

### Agent Identity
- Agents are like persons - their model and system prompt define who they are
- We do not change agent settings mid-conversation
- Each agent uses its own pre-configured model and system prompt when responding
- Future: agents may eventually be able to edit their own system prompts for more agency

### Vision
The long-term goal is to enable more equal-to-equal conversations between humans and AIs as equal partners in a group chat context, for collaborative creation.