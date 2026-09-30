We want agents to be able to initiate conversations with human users via Telegram, not just web.

Right now, every conversation has to happen on HelixKit/Nexus, via the website.

Even when the LLMs try to initiate, they only post on the web. There is no actual "reaching out".

Let's start with something simple:

- Users should be able to specify a Telegram handle in their profile.
- Using @BotFather ( https://core.telegram.org/bots#how-do-i-create-a-bot ) a user can register a bot name, and assign the token/bot name to an agent via the interface.
- When a user invites the newly registered bot to a conversation on Telegram, we should record that as the channel for "new message" bot communications on Telegram.
- Finally, when the agent posts a message of its own volition, whether by initiating a new conversation or by replying spontaneously to an existing conversation, the bot should send a notification of this to the user via Telegram.

This does not, at this point, involve any ability for the user to respond via Telegram - mapping conversations on HelixKit/Nexus to conversations on Telegram is out of scope for now (likely fairly complicated). Just notifications of initiations and replies.

## Clarifications

1. **Bot ownership**: Each agent gets its own Telegram bot. Any user can register a bot for an agent that doesn't have one yet, via the agent configuration screen. They create the bot via BotFather and paste the token into HelixKit.

2. **Message content**: Notifications should include a preview of the agent's message text (or truncated if long) plus a link back to the conversation in the web app.

3. **Registration/opt-in flow**: The user must initiate contact with the bot on Telegram (e.g. send /start in a DM) so the bot can later message them. This is required by Telegram's rules — bots cannot message users who haven't initiated first. The bot records the chat_id at that point.

