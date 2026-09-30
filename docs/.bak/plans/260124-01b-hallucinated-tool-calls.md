# Implementation Plan: Fix Hallucinated Tool Calls

**Date:** 2026-01-24
**Spec:** 260124-01
**Revision:** b

## Executive Summary

DHH's feedback is correct: the hallucinated JSON is a tool *response*, not a request. We cannot reliably reverse-engineer tool inputs from outputs in the general case.

However, for the only tool we've observed being hallucinated (SaveMemoryTool), the response echoes its inputs. We can pragmatically handle this one case and strip-only for everything else.

**Approach:** Strip JSON prefix. For SaveMemoryTool specifically, also save the memory. For unknown tools, just strip.

## Implementation

### Step 1: Message Model (~20 lines)

- [ ] Add detection and strip methods to `Message`

```ruby
# app/models/message.rb

def has_json_prefix?
  return false unless role == "assistant" && content.present?
  content.strip.match?(/\A\{.+?\}[^}]/m)
end

def strip_json_prefix!
  return unless has_json_prefix?

  transaction do
    extracted = extract_and_handle_json_blocks
    update!(content: extracted[:remaining_content])
    chat.touch
  end
end

def fixable
  has_json_prefix? && agent.present?
end

private

def extract_and_handle_json_blocks
  remaining = content.strip

  while remaining.start_with?("{") && (close_idx = find_json_end(remaining))
    json_str = remaining[0..close_idx]
    maybe_save_memory(json_str)
    remaining = remaining[(close_idx + 1)..].to_s.strip
  end

  { remaining_content: remaining }
end

def find_json_end(str)
  depth = 0
  str.each_char.with_index do |char, i|
    depth += 1 if char == "{"
    depth -= 1 if char == "}"
    return i if depth == 0
  end
  nil
end

def maybe_save_memory(json_str)
  return unless agent&.tools&.include?(SaveMemoryTool)

  parsed = JSON.parse(json_str) rescue return
  return unless parsed["memory_type"] && parsed["content"]
  return unless AgentMemory.memory_types.key?(parsed["memory_type"])

  agent.memories.create(
    content: parsed["content"].to_s.strip,
    memory_type: parsed["memory_type"]
  )
rescue => e
  Rails.logger.warn "Failed to save hallucinated memory: #{e.message}"
end
```

### Step 2: Add JSON Attribute

- [ ] Add `fixable` to JSON attributes

```ruby
# In json_attributes line:
json_attributes :role, :content, ..., :fixable
```

### Step 3: Controller Action (~10 lines)

- [ ] Add strip action to `MessagesController`

```ruby
def strip_json_prefix
  @message = Message.find(params[:id])
  @chat = set_chat_from_message

  @message.strip_json_prefix!
  redirect_to account_chat_path(@chat.account, @chat)
end

private

def set_chat_from_message
  Current.user.site_admin ? Chat.find(@message.chat_id) :
    Chat.where(id: @message.chat_id, account_id: Current.user.account_ids).first!
end
```

### Step 4: Route

- [ ] Add route

```ruby
resources :messages, only: [:update, :destroy] do
  member do
    post :retry
    post :strip_json_prefix
  end
end
```

### Step 5: Regenerate Routes

- [ ] Run `rails js_routes:generate`

### Step 6: Frontend Button

- [ ] Add fix button to message display

```svelte
{#if message.fixable}
  <button
    onclick={() => stripJsonPrefix(message.id)}
    class="btn btn-ghost btn-xs"
    title="Strip hallucinated JSON">
    <Wrench size={16} />
  </button>
{/if}
```

```javascript
async function stripJsonPrefix(messageId) {
  await fetch(stripJsonPrefixMessagePath(messageId), {
    method: 'POST',
    headers: { 'X-CSRF-Token': csrfToken }
  });
  router.reload({ only: ['messages'], preserveScroll: true });
}
```

### Step 7: Tests

- [ ] Add minimal tests

```ruby
test "has_json_prefix? detects JSON-prefixed messages" do
  msg = Message.new(role: "assistant", content: '{"success": true}Hello')
  assert msg.has_json_prefix?
end

test "strip_json_prefix! removes JSON and saves memory when applicable" do
  # Setup agent with SaveMemoryTool, create message, verify strip + memory creation
end
```

## What We're NOT Doing

Per DHH's feedback, we avoid:
- Bespoke JSON parsers with escape handling
- Tool inference engines mapping response shapes to tool names
- Generic tool execution from hallucinated responses
- 150+ lines of parsing logic in the Message model

## Why This Works

SaveMemoryTool's response format echoes its inputs:
```ruby
{ success: true, memory_type: memory.memory_type, content: memory.content }
```

The hallucinated JSON contains exactly what we need. For any other tool, we just strip without executing - that's the honest thing to do.

## Files to Modify

1. `/app/models/message.rb` - Detection, strip, and memory-save logic
2. `/app/controllers/messages_controller.rb` - Strip action
3. `/config/routes.rb` - Route
4. `/app/frontend/pages/chats/show.svelte` - Button
5. `/test/models/message_test.rb` - Tests
