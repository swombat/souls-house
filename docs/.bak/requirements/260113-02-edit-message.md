It'd be nice to have a sensible method for editing the last message in a conversation, if you're the user who posted it. This is to fix typos/etc.

This should work both on a regular browser and on mobile, so please come up with a sensible interface.

I'm thinking this could be a faint button that appears when you hover of the message on desktop. On mobile, it could be always visible next to the latest message (but faint - and make sure it's dark mode friendly).

If the button is clicked, have a pane appear from the bottom with a form to edit the message. The form should have a textarea for the message content, a button to save the changes, and a button to cancel the changes.

## Clarifications

1. **Edit scope**: Only the last user message can be edited, and only if there is no AI response after it yet. This feature is specifically for fixing typos before the message is processed by the AI.

2. **AI Response handling**: Editing is not allowed if there is already an AI response after the message. The edit button should only appear/be enabled when the last user message has no subsequent AI response.

3. **No cascading effects**: Since editing is only allowed before AI processing, there are no AI responses to delete or regenerate.