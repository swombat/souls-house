# Streaming AI Messages - Simple Implementation

## Problem
AI messages generate content incrementally. We need to stream this content to the frontend as it's being generated, instead of reloading the entire page 2-3 times per second.

## Solution
Use ActionCable to broadcast message updates directly. When AI generates content, broadcast the full message JSON. Frontend subscribes to streaming messages and updates them in place. That's it.

## Implementation

### 1. Add streaming status to Message model

```ruby
# db/migrate/xxx_add_streaming_to_messages.rb
class AddStreamingToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :streaming, :boolean, default: false
  end
end
```

### 2. Broadcast updates when streaming

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  # ... existing code ...

  after_update_commit :broadcast_streaming_update, if: :streaming?

  private

  def broadcast_streaming_update
    ActionCable.server.broadcast(
      "message_#{obfuscated_id}",
      as_json
    )
  end
end
```

### 3. Simple streaming channel

```ruby
# app/channels/message_streaming_channel.rb
class MessageStreamingChannel < ApplicationCable::Channel
  def subscribed
    message = Message.find_by_obfuscated_id(params[:id])
    reject unless message&.chat&.accessible_by?(current_user)
    stream_from "message_#{params[:id]}"
  end
end
```

### 4. Update AI job to use streaming

```ruby
# app/jobs/ai_response_job.rb
class AiResponseJob < ApplicationJob
  def perform(chat, _user_message)
    message = chat.messages.create!(
      role: "assistant",
      content: "",
      streaming: true
    )

    chat.complete do |chunk|
      next unless chunk.content
      message.update!(content: message.content + chunk.content)
    end

    message.update!(streaming: false)
  rescue => e
    message&.update!(streaming: false)
    raise
  end
end
```

### 5. Subscribe in Svelte component

```svelte
<!-- app/frontend/pages/chats/show.svelte -->
<script>
  import { onDestroy } from 'svelte';
  import { createConsumer } from '@rails/actioncable';

  // ... existing props ...

  const consumer = createConsumer();
  let subscriptions = [];

  // Subscribe to streaming messages
  $effect(() => {
    // Clean up old subscriptions
    subscriptions.forEach(s => s.unsubscribe());
    subscriptions = [];

    // Subscribe to messages that are streaming
    messages.filter(m => m.streaming).forEach(message => {
      const sub = consumer.subscriptions.create(
        {
          channel: 'MessageStreamingChannel',
          id: message.obfuscated_id
        },
        {
          received: (data) => {
            // Update message in place
            const index = messages.findIndex(m => m.id === data.id);
            if (index >= 0) {
              messages[index] = data;
            }
            // Unsubscribe if streaming is done
            if (!data.streaming) {
              sub.unsubscribe();
            }
          }
        }
      );
      subscriptions.push(sub);
    });
  });

  onDestroy(() => {
    subscriptions.forEach(s => s.unsubscribe());
  });
</script>
```

## Data Flow

1. User sends message
2. AI job creates assistant message with `streaming: true`
3. Frontend sees new message via useSync, subscribes to streaming channel
4. As AI generates content, message updates trigger ActionCable broadcast
5. Frontend receives updates, replaces message object in array
6. When complete, `streaming: false` triggers final update and unsubscribe
7. If connection drops, useSync refresh picks up current state

## Testing

```ruby
# test/models/message_test.rb
test "broadcasts updates when streaming" do
  message = create(:message, streaming: true)

  assert_broadcast_on("message_#{message.obfuscated_id}") do
    message.update!(content: "New content")
  end
end

test "does not broadcast when not streaming" do
  message = create(:message, streaming: false)

  assert_no_broadcasts("message_#{message.obfuscated_id}") do
    message.update!(content: "New content")
  end
end
```

## Implementation Steps

- [ ] Add migration for `streaming` boolean column
- [ ] Add `broadcast_streaming_update` to Message model
- [ ] Create MessageStreamingChannel (10 lines)
- [ ] Update AiResponseJob to set streaming flag
- [ ] Add ActionCable subscription in show.svelte
- [ ] Test with real AI responses

Total code: ~50 lines. Time to implement: 2 hours.