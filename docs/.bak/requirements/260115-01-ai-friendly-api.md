I have a claude code instance managing my life these days. It currently is able to access something called "Nexus" at my new job, via an MCP interface with API key.

I think this could be done via a Skill and JSON API endpoint, which is lighter than MCP. The user for this API will be an AI, most likely a Claude Code instance, and it should some kind of process for opening a browser to request a key to be created, much like MCP authentication works, but without MCP.

I want the JSON API to be able to do the following:

- Get a list of all conversations from the account that's provided the API key, with their participants, titles, a short summary of the conversation, and any associated whiteboard
  - The summary should probably be added as a field on the Chat model, generated via either RubyLLM or the Prompt system using a light model. Summary should be no more than 200 words. Summaries should not be re-generated more frequently than once per hour.
- Get the full transcript of a given conversation, not including images or thinking traces or tool calls
- Get a list of whiteboards with their titles
- Get the details of a given whiteboard
- Update the contents of a whiteboard on behalf of the user whose API key is being used
- Post a message to a conversation on behalf of the user whose API key is being used

This seems like enough to begin with, and will enable my claude code personal assistant to gather information from these group conversations and interact on my behalf!

## Clarifications

### API Key Scope & Security
- Each user creates their own API keys
- A key grants access to that account, acting as that user
- Keys are permanent until manually revoked/deleted by the user

### Authentication Flow
- Preferred: OAuth-style flow where the CLI requests a key and user approves in browser
- Fallback: If OAuth-style is too complex, a simple manual key creation screen (like GitHub personal access tokens)

### Posting Messages to Conversations
- Messages posted via API should trigger AI response only in 1-1 conversations
- In group chats, triggers remain manual (respects the existing `manual_responses` behavior)
- No rate limiting needed for now

### Whiteboard Updates
- API only needs PUT/PATCH that replaces the entire whiteboard content
- No need to differentiate manual updates from API updates in tracking