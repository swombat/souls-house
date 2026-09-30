# Implementation Plan: Fix Hallucinated Tool Calls

**Date:** 2026-01-24
**Spec:** 260124-01
**Revision:** c (final)

## Progress Tracking

- [x] Step 1: Tool Recovery Interface (SaveMemoryTool)
- [x] Step 2: Message Model Methods
- [x] Step 3: Controller Action
- [x] Step 4: Route
- [x] Step 5: Regenerate JS Routes
- [ ] Step 6: Frontend Button (separate task)
- [x] Step 7: Tests
- [x] Step 8: Code Review Fixes (2026-01-24)
  - [x] Remove duplicate `set_message_and_chat_for_fix` before_action - reuse `set_message`
  - [x] Replace O(n^2) JSON extraction with O(n) brace-counting algorithm
  - [x] DRY up SaveMemoryTool by extracting shared `create_memory` class method

## Executive Summary

Some models (Gemini, Grok) hallucinate tool responses at the start of their messages. These are fake - the tool was never actually called. However, the hallucinated JSON often contains exactly what would have been the tool's input parameters (since the model is mimicking a successful response).

Per requirements, we **execute** the tool calls. This is not "building fiction on fiction" - it is recovering the user's intent that the model failed to properly execute. The fix button:

1. Detects JSON-prefixed messages
2. Extracts and parses the JSON using `JSON.parse`
3. **Attempts to execute each tool call** via tool-specific recovery methods
4. Records successful executions (or errors) in the conversation history
5. Strips the JSON from the message content

## Architecture Overview

### Key Design Decisions

1. **Tools own their recovery logic**: Each tool class that can be recovered from a hallucination implements `self.recover_from_hallucination(parsed_json, agent:, chat:)`. This keeps tool-specific knowledge in the tool where it belongs.

2. **Proper JSON parsing**: Use `JSON.parse` to find JSON boundaries, not brace counting. This correctly handles `{"content": "braces {here}"}`.

3. **Message orchestrates, tools execute**: The Message model detects, extracts, and orchestrates. Tools decide if they can recover and perform the actual execution.

4. **Error injection**: When a tool cannot be identified or execution fails, inject an assistant message with the error details as the requirements specify.

### Data Flow

```
User clicks "Fix" button
       |
       v
POST /messages/:id/fix_hallucinated_tool_calls
       |
       v
MessagesController#fix_hallucinated_tool_calls
       |
       v
Message#fix_hallucinated_tool_calls!
       |
       +-- Extract JSON blocks using JSON.parse
       |
       +-- For each JSON block:
       |       +-- Ask registered tools if they can recover
       |       +-- If recoverable: execute, record result message
       |       +-- If not recoverable: record error message
       |
       +-- Strip JSON from message content
       +-- Save all changes in transaction
       |
       v
Inertia redirect (triggers useSync refresh)
```

## Implementation

### Step 1: Tool Recovery Interface (~30 lines total across tools)

Add `recover_from_hallucination` class method to tools that can be recovered. Start with `SaveMemoryTool` since that is the only observed case.

```ruby
# app/tools/save_memory_tool.rb

class SaveMemoryTool < RubyLLM::Tool
  # ... existing code ...

  # Attempts to recover this tool from a hallucinated response.
  # Returns { success: true, result: ... } or { error: "..." }
  def self.recover_from_hallucination(parsed_json, agent:, chat:)
    # The hallucinated response format echoes the input:
    # { success: true, memory_type: "journal", content: "..." }
    memory_type = parsed_json["memory_type"]
    content = parsed_json["content"]

    return { error: "Missing memory_type or content" } unless memory_type && content
    return { error: "Invalid memory_type: #{memory_type}" } unless AgentMemory.memory_types.key?(memory_type)

    memory = agent.memories.create!(
      content: content.to_s.strip,
      memory_type: memory_type
    )

    { success: true, tool_name: name, result: { memory_type: memory.memory_type, content: memory.content } }
  rescue ActiveRecord::RecordInvalid => e
    { error: "Failed to save memory: #{e.record.errors.full_messages.join(', ')}" }
  end

  # Determines if this tool can potentially recover from the given JSON structure
  def self.recoverable_from?(parsed_json)
    parsed_json.key?("memory_type") && parsed_json.key?("content")
  end
end
```

### Step 2: Message Model Methods (~50 lines)

- [x] Add detection, extraction, and fix methods to `Message`

```ruby
# app/models/message.rb

# Add to json_attributes line:
# json_attributes :role, :content, ..., :fixable

def has_json_prefix?
  return false unless role == "assistant" && content.present?
  content.strip.start_with?("{")
end

def fixable
  has_json_prefix? && agent.present?
end

def fix_hallucinated_tool_calls!
  raise "Not an assistant message" unless role == "assistant"
  raise "No JSON prefix detected" unless has_json_prefix?
  raise "Cannot fix: message has no agent" unless agent.present?

  transaction do
    remaining_content = content.strip
    json_blocks = []

    # Extract all leading JSON blocks
    while remaining_content.start_with?("{")
      extracted = extract_first_json(remaining_content)
      break unless extracted

      json_blocks << extracted[:json]
      remaining_content = extracted[:remainder].lstrip
    end

    # Process each JSON block
    json_blocks.each do |json_str|
      parsed = JSON.parse(json_str) rescue nil
      next unless parsed

      result = attempt_tool_recovery(parsed)
      record_tool_result(result, json_str)
    end

    # Strip JSON from content
    update!(content: remaining_content)
    chat.touch
  end
end

private

def extract_first_json(text)
  # Use JSON.parse to find proper JSON boundaries
  (1..text.length).each do |i|
    next unless text[i - 1] == "}"
    begin
      JSON.parse(text[0...i])
      return { json: text[0...i], remainder: text[i..].to_s }
    rescue JSON::ParserError
      next
    end
  end
  nil
end

def attempt_tool_recovery(parsed_json)
  # Find a tool that can recover from this JSON structure
  recoverable_tools.each do |tool_class|
    next unless tool_class.respond_to?(:recoverable_from?) && tool_class.recoverable_from?(parsed_json)
    next unless agent.tools.include?(tool_class)

    return tool_class.recover_from_hallucination(parsed_json, agent: agent, chat: chat)
  end

  { error: "Could not identify tool from JSON structure" }
end

def recoverable_tools
  # Tools that implement the recovery interface
  [SaveMemoryTool].select { |t| t.respond_to?(:recover_from_hallucination) }
end

def record_tool_result(result, original_json)
  if result[:success]
    # Create a successful tool execution record
    # Insert just before this message (using created_at manipulation)
    chat.messages.create!(
      role: "assistant",
      content: "",
      agent: agent,
      tools_used: [result[:tool_name]],
      created_at: created_at - 1.second
    )
  else
    # Create an error message explaining the failure
    chat.messages.create!(
      role: "assistant",
      content: "Tool call failed: #{original_json.truncate(200)}\n\nError: #{result[:error]}",
      agent: agent,
      created_at: created_at - 1.second
    )
  end
end
```

### Step 3: Controller Action (~15 lines)

- [x] Add `fix_hallucinated_tool_calls` action to `MessagesController`

```ruby
# app/controllers/messages_controller.rb

# Add to before_action exclusions:
# before_action :set_chat, except: [:retry, :update, :destroy, :fix_hallucinated_tool_calls]
# Add new before_action:
# before_action :set_message_and_chat_for_fix, only: :fix_hallucinated_tool_calls

def fix_hallucinated_tool_calls
  @message.fix_hallucinated_tool_calls!
  redirect_to account_chat_path(@chat.account, @chat)
rescue StandardError => e
  Rails.logger.error "Fix hallucinated tool calls failed: #{e.message}"
  redirect_to account_chat_path(@chat.account, @chat), alert: "Failed to fix: #{e.message}"
end

private

def set_message_and_chat_for_fix
  @message = Message.find(params[:id])
  @chat = if Current.user.site_admin
    Chat.find(@message.chat_id)
  else
    Chat.where(id: @message.chat_id, account_id: Current.user.account_ids).first!
  end
end
```

### Step 4: Route

- [x] Add route for the fix action

```ruby
# config/routes.rb

resources :messages, only: [:update, :destroy] do
  member do
    post :retry
    post :fix_hallucinated_tool_calls
  end
end
```

### Step 5: Regenerate JS Routes

- [x] Run `rails js:routes` to update frontend routes

### Step 6: Frontend Button

- [ ] Add fix button to message display

```svelte
<!-- In app/frontend/pages/chats/show.svelte, in the assistant message actions area -->
{#if message.fixable}
  <button
    onclick={() => fixHallucinatedToolCalls(message.id)}
    class="inline-flex items-center gap-1 text-xs text-muted-foreground
           hover:text-amber-500 transition-colors"
    title="Fix hallucinated tool call">
    <Wrench size={14} />
    Fix
  </button>
{/if}
```

- [ ] Add import and handler

```javascript
import { Wrench } from 'phosphor-svelte';
import { fixHallucinatedToolCallsMessagePath } from '@/routes';

async function fixHallucinatedToolCalls(messageId) {
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || '';
  await fetch(fixHallucinatedToolCallsMessagePath(messageId), {
    method: 'POST',
    headers: { 'X-CSRF-Token': csrfToken }
  });
  router.reload({ only: ['messages'], preserveScroll: true });
}
```

### Step 7: Tests

- [x] Add model tests
- [x] Add tool recovery tests

### Step 8: Code Review Fixes

- [x] Remove duplicate `set_message_and_chat_for_fix` - now reuses `set_message`
- [x] Replace O(n^2) JSON extraction with O(n) brace-counting algorithm
- [x] DRY up SaveMemoryTool with shared `create_memory` class method

## Files Modified

1. `/app/models/message.rb` - Add detection, extraction, and fix orchestration
2. `/app/tools/save_memory_tool.rb` - Add recovery interface
3. `/app/controllers/messages_controller.rb` - Add fix action
4. `/config/routes.rb` - Add route
5. `/test/models/message_test.rb` - Add model tests
6. `/test/tools/save_memory_tool_test.rb` - Add tool recovery tests
7. `/test/fixtures/agents.yml` - Add test fixtures

## Why This Approach is Correct

### It Follows the Requirements

The requirements explicitly state:
1. Parse the JSON from the message content
2. **Attempt to execute the tool call with the arguments**
3. **Record it in the conversation history as if it happened just before the message**
4. Strip the JSON from the message content
5. If execution fails, inject an error message instead

This plan implements all five requirements.

### It Uses DHH's Valid Technical Feedback

1. **JSON.parse for boundaries**: No brace counting. Properly handles nested JSON and strings containing braces.

2. **Encapsulation**: Tool-specific recovery logic lives in the tool (`SaveMemoryTool.recover_from_hallucination`), not in the Message model. If we add recovery for other tools later, we add it to those tools.

3. **Message stays clean**: The Message model orchestrates but does not contain tool-specific knowledge.

### It Is Pragmatic

- Only `SaveMemoryTool` recovery is implemented initially (the only observed case)
- The interface allows easy addition of more recoverable tools later
- Unknown JSON structures are handled gracefully with error messages
- The user is informed when recovery fails

## Future Extensions

When other tools are observed being hallucinated, add to those tools:

```ruby
class WhiteboardTool < RubyLLM::Tool
  def self.recoverable_from?(parsed_json)
    # Check for whiteboard-like response structure
  end

  def self.recover_from_hallucination(parsed_json, agent:, chat:)
    # Implement recovery
  end
end
```

And add the tool class to `Message#recoverable_tools`.
