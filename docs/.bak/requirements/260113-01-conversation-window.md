There is an extremely long conversation from prod at http://localhost:3100/accounts/PNvAYr/chats/OYzDjK (150+ messages, 1.3M tokens).

The UI becomes unwieldy at these lengths.

Please come up with a way to have the server only send the last X messages/tokens to the client, with a "scroll up to see more" functionality where the beginning of the conversation is loaded as the user scrolls up.

I think there should also be a warning that appears next to the token count stating the conversation is getting very long, after 100k tokens. After 200k tokens, the whole title bar should go light red and the warning should suggest starting a new conversation.

## Clarifications

1. **Window Size**: Load last 30 messages initially, and load 30 messages at a time when scrolling up.

2. **Scroll-to-load Behavior**: Prepend a batch of 30 messages when the user scrolls near the top of the conversation.

3. **Warning Thresholds**:
   - **100k tokens**: Amber warning tag next to token count
   - **150k tokens**: Red warning tag next to token count
   - **200k tokens**: Red chat heading + suggest starting a new conversation