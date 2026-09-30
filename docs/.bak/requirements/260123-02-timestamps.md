Currently, agents have no idea about the time elapsed in conversations, or when messages were sent.

Please come up with a sensible, elegant way to add timestamps to both user and agent messages, so agents can get a sense of the passage of time in conversations, the time when the user (or an agent) sent a message, and the current time at the location where human participants in a conversation are located.

This should ideally be done in a way that doesn't consume lots of tokens, but also doesn't interfere with the conversation flow.

## Clarifications

1. **Message timestamps**: The `Message` model already has `created_at` timestamps in the database.

2. **User timezone**: The `User` model delegates `timezone` to `Profile`, so timezone data is already available.

3. **Integration point**: The key method is `Chat#format_message_for_context` which formats messages for the LLM context, and `Chat#system_message_for` which builds system prompts.

4. **Format approach**: Use occasional full timestamps (date + time + timezone) at conversation start or after significant gaps, with shorter timestamps for recent messages. Format should be optimized for AI intelligibility and token efficiency.