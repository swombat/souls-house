The useSync framework is fantastic for auto-updating objects on the page, but there are some specific cases, like streaming updates for a specific object like a message in a chat, that are not ideal to handle via this method, because it is inefficient for such frequent update cases.

In the case of a message in a chat, for example, we don't want the workflow of:

1. Message has some test appended
2. ActionCable broadcasts that Message#123 needs update
3. useSync detects the change and reloads the page including grabbing all the chats again
4. The page reloads and the message is displayed

Instead, we want the workflow to be:

1. Message has some text appended
2. A different ActionCable channel receives the updated message json
3. The frontend receives the updated message json and updates the message in the UI

This is more efficient for such frequent update cases.

Design a new ActionCable channel and a front-end approach to handle this. It is understood that this may not be as elegant as the useSync framework - it is an optimisation for frequent update cases. But it should still not be ugly, and it should still function by clear and simple declarative code in the models, with perhaps a little bit more explicit wiring in the frontend.

I expect that models that do this kind of streaming update will not be at the same time doing the useSync type update - you get one or the other, not both.

The logic should elegantly support the following workflows:

### Workflow 1
1. Frontend is following a chat via useSync
2. A new message is appended to the chat (by this user)
3. The frontend receives the updated message json, appends it to the messages collection, subscribes to message updates for that message and updates it in real time

### Workflow 2
1. Frontend is following a chat via useSync
2. A new message is appended to the chat (by another user)
3. The frontend is notified of the new message via useSync, the page reloads to update the messages collection
4. The frontend subscribes to message updates for that message and updates it in real time

Please come up with a tight and elegant solution that does not require a lot of extra wiring in the frontend or models, for this specific type of use case.

## Clarifications

1. **Partial vs Full Updates**: Send the full message content with each update (10-20kb per message, 2-3 times per second, debounced). Can optimize later if needed.

2. **Subscription Lifecycle**: Frontend needs to be notified when updates are complete for a message. Hook into ruby-llm completion events if possible, otherwise design an elegant alternative. Automatic unsubscription when streaming completes.

3. **Error Handling & Recovery**: On connection drop, fall back to page refresh via useSync. The refresh should detect messages in streaming mode and restart streaming. Since full message JSON is sent with each update, no need to handle missed updates.

4. **Authorization Scope**: Verify authorization only on initial subscription, not on every update.

5. **Update Types**: This feature is specifically for streaming text updates only. Other update types should continue using useSync.
