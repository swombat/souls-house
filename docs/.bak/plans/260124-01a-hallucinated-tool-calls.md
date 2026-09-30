# Implementation Plan: Fix Hallucinated Tool Calls

**Date:** 2026-01-24
**Spec:** 260124-01
**Revision:** a

## Executive Summary

Gemini and Grok models sometimes hallucinate tool calls by embedding JSON that looks like tool responses directly in their message content, followed by actual text. For example:

```
{success: true, memory_type: "journal", content: "..."} You saw right through me...
```

This plan implements a "fix" button that:
1. Detects messages with JSON-prefixed content
2. Parses and attempts to execute the hallucinated tool call(s)
3. Strips the JSON from the message content
4. Records the execution result in the conversation history

## Architecture Overview

### Detection Strategy

Rather than trying to match against actual tool definitions (which would be fragile), we detect any JSON-ish content at the start of assistant messages. These are hallucinated responses mimicking what the model thinks a successful tool call would look like.

**Pattern:** Message content starts with `{` and contains `}` followed by non-whitespace text.

### Data Flow

```
User clicks "Fix" button
       |
       v
Frontend POST /messages/:id/fix_hallucinated_tool
       |
       v
MessagesController#fix_hallucinated_tool
       |
       v
Message#fix_hallucinated_tool! (model method)
       |
       +-- Parse JSON blocks from content
       +-- For each JSON block:
       |       +-- Try to identify tool from JSON structure
       |       +-- Execute tool if possible, record result
       |       +-- Create tool result message before this message
       +-- Strip JSON from message content
       +-- Save all changes in transaction
       |
       v
Inertia redirect (triggers useSync refresh)
```

## Step-by-Step Implementation

### Step 1: Add Detection Method to Message Model

- [ ] Add `has_hallucinated_tool_calls?` method to `Message` model

```ruby
# app/models/message.rb

def has_hallucinated_tool_calls?
  return false unless role == "assistant" && content.present?

  trimmed = content.strip
  return false unless trimmed.start_with?("{")

  # Check if there's text content after the JSON
  last_brace = trimmed.rindex("}")
  return false unless last_brace

  after_json = trimmed[(last_brace + 1)..].to_s.strip
  after_json.present?
end
```

### Step 2: Add JSON Parsing Helper

- [ ] Add `extract_hallucinated_tool_calls` method to parse JSON blocks

```ruby
# app/models/message.rb

def extract_hallucinated_tool_calls
  return [] unless has_hallucinated_tool_calls?

  results = []
  remaining = content.strip

  while remaining.start_with?("{")
    # Find matching closing brace (handle nested objects)
    json_str, rest = extract_json_object(remaining)
    break unless json_str

    begin
      parsed = JSON.parse(json_str.gsub(/(\w+):/, '"\1":')) # Handle unquoted keys
      results << { raw: json_str, parsed: parsed }
    rescue JSON::ParserError
      # Not valid JSON, stop parsing
      break
    end

    remaining = rest.strip
  end

  results
end

private

def extract_json_object(str)
  return nil unless str.start_with?("{")

  depth = 0
  in_string = false
  escape_next = false

  str.each_char.with_index do |char, i|
    if escape_next
      escape_next = false
      next
    end

    case char
    when '\\'
      escape_next = true if in_string
    when '"'
      in_string = !in_string
    when '{'
      depth += 1 unless in_string
    when '}'
      depth -= 1 unless in_string
      if depth == 0
        return [str[0..i], str[(i + 1)..]]
      end
    end
  end

  nil # No matching close brace found
end
```

### Step 3: Add Tool Execution Logic

- [ ] Add `fix_hallucinated_tool!` method

```ruby
# app/models/message.rb

def fix_hallucinated_tool!
  raise "Not an assistant message" unless role == "assistant"
  raise "No hallucinated tool calls detected" unless has_hallucinated_tool_calls?
  raise "Cannot fix: chat does not have an agent" unless agent.present?

  tool_calls = extract_hallucinated_tool_calls
  raise "No valid tool calls found" if tool_calls.empty?

  transaction do
    messages_to_insert = []

    tool_calls.each do |tc|
      result = execute_hallucinated_tool_call(tc[:parsed])
      messages_to_insert << build_tool_result_message(tc, result)
    end

    # Insert tool result messages just before this message
    messages_to_insert.each do |msg_attrs|
      chat.messages.create!(
        msg_attrs.merge(
          created_at: created_at - 1.second,
          agent: agent
        )
      )
    end

    # Strip JSON from content
    new_content = content_without_json_prefix
    update!(content: new_content)

    # Touch chat to trigger sync
    chat.touch
  end
end

private

def execute_hallucinated_tool_call(parsed_json)
  tool_name = infer_tool_name(parsed_json)
  return { error: "Could not identify tool from JSON structure" } unless tool_name

  tool_class = tool_name.constantize rescue nil
  return { error: "Tool class #{tool_name} not found" } unless tool_class

  # Check if agent has this tool enabled
  unless agent.tools.include?(tool_class)
    return { error: "Tool #{tool_name} not enabled for agent #{agent.name}" }
  end

  begin
    tool = tool_class.new(chat: chat, current_agent: agent)
    args = extract_tool_arguments(tool_class, parsed_json)
    result = tool.execute(**args)
    { success: true, tool_name: tool_name, result: result }
  rescue StandardError => e
    { error: "Tool execution failed: #{e.message}" }
  end
end

def infer_tool_name(parsed_json)
  # Match based on JSON structure to known tool response patterns
  if parsed_json.key?("memory_type") && parsed_json.key?("content")
    "SaveMemoryTool"
  elsif parsed_json.key?("type") && parsed_json["type"].to_s.start_with?("board")
    "WhiteboardTool"
  elsif parsed_json.key?("action") && %w[search fetch].include?(parsed_json["action"])
    "WebTool"
  else
    nil
  end
end

def extract_tool_arguments(tool_class, parsed_json)
  # Map JSON response back to tool parameters
  case tool_class.name
  when "SaveMemoryTool"
    { content: parsed_json["content"], memory_type: parsed_json["memory_type"] }
  when "WhiteboardTool"
    # The hallucinated JSON is the response, not the request - try to infer action
    { action: infer_whiteboard_action(parsed_json), **parsed_json.symbolize_keys.except(:type) }
  else
    parsed_json.symbolize_keys
  end
end

def infer_whiteboard_action(parsed_json)
  case parsed_json["type"]
  when "board_created" then "create"
  when "board_updated" then "update"
  when "board_deleted" then "delete"
  when "board_list" then "list"
  else "get"
  end
end

def build_tool_result_message(tool_call, result)
  if result[:success]
    {
      role: "assistant",
      content: "", # Empty content for tool call message
      tools_used: [result[:tool_name]]
    }
  else
    {
      role: "assistant",
      content: "Tool call failed: #{tool_call[:raw]}\n\nError: #{result[:error]}"
    }
  end
end

def content_without_json_prefix
  remaining = content.strip

  while remaining.start_with?("{")
    _, rest = extract_json_object(remaining)
    break unless rest
    remaining = rest.strip
  end

  remaining
end
```

### Step 4: Add Controller Action

- [ ] Add `fix_hallucinated_tool` action to `MessagesController`

```ruby
# app/controllers/messages_controller.rb

# Add to routes.rb first, then add action:

def fix_hallucinated_tool
  @message = Message.find(params[:id])
  @chat = authorize_message_chat(@message)

  unless @message.has_hallucinated_tool_calls?
    return respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "No hallucinated tool calls detected" }
      format.json { render json: { error: "No hallucinated tool calls detected" }, status: :unprocessable_entity }
    end
  end

  @message.fix_hallucinated_tool!

  respond_to do |format|
    format.html { redirect_to account_chat_path(@chat.account, @chat), notice: "Tool call fixed successfully" }
    format.json { head :ok }
  end
rescue StandardError => e
  Rails.logger.error "Fix hallucinated tool failed: #{e.message}"
  respond_to do |format|
    format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Failed to fix: #{e.message}" }
    format.json { render json: { error: e.message }, status: :unprocessable_entity }
  end
end

private

def authorize_message_chat(message)
  if Current.user.site_admin
    Chat.find(message.chat_id)
  else
    Chat.where(id: message.chat_id, account_id: Current.user.account_ids).first!
  end
end
```

### Step 5: Add Route

- [ ] Add route for the fix action

```ruby
# config/routes.rb

resources :messages, only: [:update, :destroy] do
  member do
    post :retry
    post :fix_hallucinated_tool  # Add this line
  end
end
```

### Step 6: Regenerate JS Routes

- [ ] Run `rails js_routes:generate` to update frontend routes

### Step 7: Add Frontend Button

- [ ] Add `fixable` attribute to message JSON

```ruby
# app/models/message.rb

json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                :completed, :created_at_formatted, :created_at_hour, :streaming,
                :files_json, :content_html, :tools_used, :tool_status,
                :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                :editable, :deletable, :fixable,  # Add :fixable
                :moderation_flagged, :moderation_severity, :moderation_scores

def fixable
  has_hallucinated_tool_calls? && agent.present?
end
```

- [ ] Add fix button to message display in `show.svelte`

```svelte
<!-- In the assistant message section, after the dropdown menu or similar -->
{#if message.fixable}
  <button
    onclick={() => fixHallucinatedTool(message.id)}
    class="p-1.5 rounded-full text-muted-foreground/50 hover:text-amber-500 hover:bg-amber-50 dark:hover:bg-amber-950
           opacity-50 hover:opacity-100 md:opacity-0 md:group-hover:opacity-100 transition-opacity
           focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring"
    title="Fix hallucinated tool call">
    <Wrench size={20} weight="regular" />
  </button>
{/if}
```

- [ ] Add the fix function in the script section

```javascript
import { Wrench } from 'phosphor-svelte';
import { fixHallucinatedToolMessagePath } from '@/routes';

async function fixHallucinatedTool(messageId) {
  try {
    const response = await fetch(fixHallucinatedToolMessagePath(messageId), {
      method: 'POST',
      headers: {
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        'Accept': 'application/json',
      },
    });

    if (response.ok) {
      successMessage = 'Tool call fixed successfully';
      setTimeout(() => successMessage = null, 3000);
      router.reload({ only: ['messages'], preserveScroll: true });
    } else {
      const data = await response.json();
      errorMessage = data.error || 'Failed to fix tool call';
      setTimeout(() => errorMessage = null, 3000);
    }
  } catch (error) {
    errorMessage = 'Failed to fix tool call';
    setTimeout(() => errorMessage = null, 3000);
  }
}
```

### Step 8: Add Tests

- [ ] Add model tests for detection and fixing

```ruby
# test/models/message_test.rb

class MessageTest < ActiveSupport::TestCase
  test "has_hallucinated_tool_calls? returns false for normal messages" do
    message = messages(:normal_assistant_message)
    assert_not message.has_hallucinated_tool_calls?
  end

  test "has_hallucinated_tool_calls? returns true for JSON-prefixed messages" do
    message = Message.new(
      role: "assistant",
      content: '{success: true, memory_type: "journal", content: "test"}You saw right through me.'
    )
    assert message.has_hallucinated_tool_calls?
  end

  test "has_hallucinated_tool_calls? returns false for pure JSON messages" do
    message = Message.new(
      role: "assistant",
      content: '{"success": true}'
    )
    assert_not message.has_hallucinated_tool_calls?
  end

  test "extract_hallucinated_tool_calls parses single JSON block" do
    message = Message.new(
      role: "assistant",
      content: '{"success": true, "memory_type": "journal"}Some text'
    )
    calls = message.extract_hallucinated_tool_calls
    assert_equal 1, calls.length
    assert_equal "journal", calls.first[:parsed]["memory_type"]
  end

  test "extract_hallucinated_tool_calls parses multiple JSON blocks" do
    message = Message.new(
      role: "assistant",
      content: '{"type": "one"}{"type": "two"}Actual content'
    )
    calls = message.extract_hallucinated_tool_calls
    assert_equal 2, calls.length
  end

  test "fix_hallucinated_tool! strips JSON and creates tool result message" do
    # Setup: Create chat with agent that has SaveMemoryTool enabled
    agent = agents(:memory_enabled_agent)
    chat = chats(:group_chat_with_agent)

    message = chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: '{"success": true, "memory_type": "journal", "content": "Test memory"}You saw right through me.'
    )

    assert_difference -> { chat.messages.count }, 1 do
      message.fix_hallucinated_tool!
    end

    message.reload
    assert_equal "You saw right through me.", message.content
  end
end
```

- [ ] Add controller tests

```ruby
# test/controllers/messages_controller_test.rb

test "fix_hallucinated_tool fixes message with hallucinated tool call" do
  sign_in users(:admin)
  message = messages(:hallucinated_tool_message)

  post fix_hallucinated_tool_message_path(message)

  assert_redirected_to account_chat_path(message.chat.account, message.chat)
  message.reload
  assert_not message.has_hallucinated_tool_calls?
end

test "fix_hallucinated_tool returns error for message without hallucinated calls" do
  sign_in users(:admin)
  message = messages(:normal_message)

  post fix_hallucinated_tool_message_path(message), as: :json

  assert_response :unprocessable_entity
end
```

## Database/Schema Changes

None required. This feature uses existing tables and columns.

## Error Handling Approach

1. **Detection Errors**: If JSON parsing fails, treat as "no hallucinated tool calls"
2. **Tool Not Found**: Record error message in place of successful tool result
3. **Tool Execution Failure**: Record error with tool details and error message
4. **Agent Missing**: Button not shown if message has no agent
5. **Authorization**: Use same pattern as other message actions

## Edge Cases

1. **Multiple JSON blocks**: Handle all in sequence
2. **Nested JSON**: Proper brace matching for nested objects
3. **Unquoted keys**: Convert `{success: true}` to `{"success": true}`
4. **Invalid JSON**: Stop at first unparseable block
5. **Unknown tool structure**: Record as error, still strip JSON
6. **Tool not enabled for agent**: Record as error explaining which tool was missing

## Potential Improvements (Future)

1. Add confirmation dialog before fixing
2. Show preview of what will be extracted
3. Allow manual correction of parsed values
4. Track which messages were fixed for analytics

## Testing Strategy

1. **Unit tests**: Message model methods for detection and parsing
2. **Integration tests**: Controller action with various scenarios
3. **Manual testing**: Test with real Gemini/Grok hallucinated responses
4. **Frontend**: Verify button appears only when appropriate, triggers correct action

## Files to Modify

1. `/app/models/message.rb` - Add detection, parsing, and fix methods
2. `/app/controllers/messages_controller.rb` - Add fix action
3. `/config/routes.rb` - Add route
4. `/app/frontend/pages/chats/show.svelte` - Add fix button
5. `/test/models/message_test.rb` - Add unit tests
6. `/test/controllers/messages_controller_test.rb` - Add controller tests
