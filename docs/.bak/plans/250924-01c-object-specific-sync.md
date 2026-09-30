# Object-Specific Streaming Sync - Final Specification

## Executive Summary
A Rails-worthy implementation for streaming individual message updates during AI generation. Uses ActionCable broadcasts with Turbo-inspired patterns, requiring only ~50 lines of actual code changes.

## Architecture Overview

### Core Principle
Leverage Rails' broadcasting infrastructure with object-specific channels, similar to Turbo Streams but adapted for Svelte's reactive model.

### Data Flow
1. AI job broadcasts content chunks to specific message channel
2. SyncChannel already handles object-specific subscriptions
3. Svelte component subscribes to individual message updates
4. Content updates stream in real-time without page props

## Implementation Plan

### Step 1: Add Stream Broadcasting to Message Model

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  # ... existing code ...

  # Stream content updates to this specific message's channel
  def stream_content(chunk)
    update_column(:content, (content.to_s + chunk))
    broadcast_replace_to self,
      target: "message_#{obfuscated_id}_content",
      partial: "messages/content",
      locals: { message: self }
  end

  # For non-Turbo clients, also send via ActionCable
  def broadcast_content_update
    ActionCable.server.broadcast(
      "Message:#{obfuscated_id}",
      { action: "update", content: content }
    )
  end
end
```

### Step 2: Update AI Response Job

```ruby
# app/jobs/ai_response_job.rb
class AiResponseJob < ApplicationJob
  def perform(chat, _user_message)
    ai_message = nil

    chat.on_new_message do
      ai_message = chat.messages.order(:created_at).last
    end

    chat.on_end_message do |message|
      ai_message ||= chat.messages.order(:created_at).last
      next unless ai_message

      finalize_message!(ai_message, message)
    end

    chat.complete do |chunk|
      next unless chunk.content

      ai_message ||= chat.messages.order(:created_at).last
      next unless ai_message

      # Stream the content update
      ai_message.stream_content(chunk.content)
      ai_message.broadcast_content_update
    end
  ensure
    # Ensure final state is broadcast even if streaming fails
    ai_message&.broadcast_refresh if ai_message&.respond_to?(:broadcast_refresh)
  end

  private

  def finalize_message!(ai_message, ruby_llm_message)
    attributes = {
      content: extract_message_content(ruby_llm_message.content),
      model_id: ruby_llm_message.model_id,
      input_tokens: ruby_llm_message.input_tokens,
      output_tokens: ruby_llm_message.output_tokens
    }

    ai_message.update!(attributes.compact)
    ai_message.broadcast_refresh
  end

  # ... rest remains the same ...
end
```

### Step 3: Add Svelte Message Subscription

```javascript
// app/frontend/lib/use-message-stream.js
import { onDestroy } from 'svelte';
import { subscribe } from '$lib/sync-manager';

export function useMessageStream(messageId, onContent) {
  if (!messageId) return () => {};

  return subscribe(`Message:${messageId}`, (data) => {
    if (data.action === 'update' && data.content) {
      onContent(data.content);
    }
  });
}
```

### Step 4: Update Chat Component

```svelte
<!-- app/frontend/pages/chats/show.svelte -->
<script>
  import { useMessageStream } from '$lib/use-message-stream';
  // ... existing imports ...

  let { chat, chats = [], messages = [], account } = $props();

  // Track streaming messages
  let streamingContent = $state(new Map());

  // Subscribe to message streams with reactive statement
  $effect(() => {
    // Clean up old subscriptions
    const unsubscribers = [];

    // Subscribe to any assistant messages that are pending
    messages.forEach(message => {
      if (message.role === 'assistant' && message.status === 'pending') {
        const unsub = useMessageStream(message.id, (content) => {
          streamingContent.set(message.id, content);
          streamingContent = new Map(streamingContent); // Trigger reactivity
        });
        unsubscribers.push(unsub);
      }
    });

    // Cleanup function
    return () => unsubscribers.forEach(fn => fn?.());
  });

  // Get display content for a message
  function getMessageContent(message) {
    if (streamingContent.has(message.id)) {
      return streamingContent.get(message.id);
    }
    return message.content || '';
  }
</script>

<!-- In the template, update assistant message display -->
{#if message.role === 'assistant'}
  <div class="flex justify-start">
    <div class="max-w-[70%]">
      <Card.Root>
        <Card.Content class="p-4">
          {#if message.status === 'failed'}
            <div class="text-red-600 mb-2 text-sm">Failed to generate response</div>
            <Button variant="outline" size="sm" on:click={() => retryMessage(message.id)}>
              <ArrowClockwise size={14} class="mr-2" />
              Retry
            </Button>
          {:else if message.status === 'pending' && !getMessageContent(message)}
            <div class="text-muted-foreground text-sm">Thinking...</div>
          {:else}
            <div class="whitespace-pre-wrap break-words">
              {getMessageContent(message)}
            </div>
          {/if}
        </Card.Content>
      </Card.Root>
    </div>
  </div>
{/if}
```

### Step 5: Extend SyncChannel (Already Compatible)

```ruby
# app/channels/sync_channel.rb
# No changes needed! Current implementation already handles:
# - Object-specific subscriptions via "Message:#{id}"
# - Authorization via accessible_by?
# - Proper streaming setup
```

## Testing Strategy

- [ ] Test message content streaming during AI generation
- [ ] Verify proper cleanup of subscriptions when navigating away
- [ ] Test error handling when streaming fails mid-generation
- [ ] Verify final content matches after streaming completes
- [ ] Test multiple concurrent message streams

## Edge Cases

1. **Connection drops during streaming**: `ensure` block guarantees final broadcast
2. **Navigation during generation**: Svelte effect cleanup handles unsubscription
3. **Multiple messages streaming**: Map tracks each message independently
4. **Failed generation**: Error state properly displayed, retry available

## Performance Considerations

- Uses `update_column` to avoid callbacks during streaming
- Reactive statement ensures clean subscription management
- Map-based state for O(1) content lookups
- Minimal DOM updates via Svelte's fine-grained reactivity

## Security

- Relies on existing `accessible_by?` authorization in SyncChannel
- No direct database access from frontend
- Content sanitization preserved through existing render pipeline

## Migration Path

This is purely additive - no breaking changes:
1. Deploy Rails changes (Message model + AI job)
2. Deploy frontend changes (Svelte components)
3. Streaming automatically activates for new messages

## Notes

This implementation embraces Rails conventions while respecting Svelte's reactive model. The `ensure` block pattern and reactive statements make the code more robust and idiomatic. The optional `broadcast_replace_to` provides a path toward Turbo integration if needed in the future.