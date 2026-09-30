# Multi-Threaded Thinking: Cross-Conversation Awareness

## Executive Summary

Give agents awareness of their other active conversations by injecting short summaries into the system prompt, and let them pull full context from another conversation on demand via a new `BorrowContextTool`. Summaries are per-agent, debounced per-conversation, and generated asynchronously. Borrowed context is ephemeral -- included in the system prompt for exactly one activation, then cleared.

Three components:

1. **Per-agent conversation summaries** stored on `ChatAgent` (not `Chat`), generated via background job with 5-minute per-conversation debounce
2. **Cross-conversation context block** appended to the system prompt in `Chat#system_message_for`
3. **BorrowContextTool** that stages messages from another conversation into the system prompt for a single activation

---

## Architecture Overview

### Why summaries live on ChatAgent, not Chat

The requirements say agents should summarize conversations "for themselves, with their system prompt." Different agents see the same conversation differently. A security-focused agent emphasizes different aspects than a creative writing agent. Storing the summary on the join table `ChatAgent` lets each agent maintain its own perspective.

The existing `Chat#summary` and `Chat#summary_generated_at` columns serve a different purpose (API-facing, third-person summaries). These remain untouched.

### Data Flow

```
Message created
  -> after_create_commit: GenerateAgentSummaryJob.perform_later(chat, agent)
     (for each agent in the chat)
  -> Job checks debounce (5 min per ChatAgent)
  -> Job generates 2-line summary via Prompt with agent's summary_prompt
  -> Stores on ChatAgent#agent_summary, ChatAgent#agent_summary_generated_at

Agent responds in any conversation
  -> Chat#system_message_for(agent) builds system prompt
  -> Queries agent's other ChatAgents with recent summaries
  -> Appends "# Your Other Conversations" block

Agent calls BorrowContextTool
  -> Tool sets ChatAgent#borrowed_context_json on current ChatAgent
  -> Next activation: system prompt includes borrowed messages
  -> After inclusion: borrowed_context_json is cleared
```

---

## Step-by-Step Implementation

### 1. Database Migration

- [ ] Create migration `AddMultiThreadedThinkingFields`

```ruby
class AddMultiThreadedThinkingFields < ActiveRecord::Migration[8.1]
  def change
    # Per-agent summaries on the join table
    add_column :chat_agents, :agent_summary, :text
    add_column :chat_agents, :agent_summary_generated_at, :datetime

    # Borrowed context (JSON array of messages, cleared after one use)
    add_column :chat_agents, :borrowed_context_json, :jsonb

    # Per-agent summary identity prompt
    add_column :agents, :summary_prompt, :text

    # Index for finding recent conversations per agent
    add_index :chat_agents, [:agent_id, :agent_summary_generated_at],
              name: "index_chat_agents_on_agent_summary_recency"
  end
end
```

**Columns explained:**

| Column | Table | Type | Purpose |
|--------|-------|------|---------|
| `agent_summary` | `chat_agents` | `text` | This agent's 2-line summary of this conversation |
| `agent_summary_generated_at` | `chat_agents` | `datetime` | Debounce timestamp |
| `borrowed_context_json` | `chat_agents` | `jsonb` | Staged messages for next activation (cleared after use) |
| `summary_prompt` | `agents` | `text` | Custom identity prompt for summary generation |

### 2. Model Changes

#### 2a. ChatAgent Model

- [ ] Add summary and borrowed context methods to `ChatAgent`

```ruby
class ChatAgent < ApplicationRecord
  SUMMARY_COOLDOWN = 5.minutes

  # ... existing code ...

  def summary_stale?
    agent_summary_generated_at.nil? || agent_summary_generated_at < SUMMARY_COOLDOWN.ago
  end

  def borrowed_context?
    borrowed_context_json.present?
  end

  def consume_borrowed_context!
    return nil unless borrowed_context?
    context = borrowed_context_json
    update_columns(borrowed_context_json: nil)
    context
  end
end
```

#### 2b. Agent Model

- [ ] Add `summary_prompt` to validations and `json_attributes`
- [ ] Add default summary prompt constant

```ruby
class Agent < ApplicationRecord
  # ... existing validations ...
  validates :summary_prompt, length: { maximum: 10_000 }

  # Add to json_attributes line:
  json_attributes :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
                  :summary_prompt,
                  # ... rest unchanged

  DEFAULT_SUMMARY_PROMPT = <<~PROMPT.freeze
    You are summarizing a conversation you are participating in. This summary is for
    your own reference so you can track what is happening across multiple conversations.

    Focus on the current STATE of the conversation:
    - What is being worked on right now?
    - What decisions are pending?
    - What has been agreed or resolved?

    Do NOT narrate what happened. Describe where things stand.

    Write exactly 2 lines. Be specific and concrete.
  PROMPT

  def effective_summary_prompt
    summary_prompt.presence || DEFAULT_SUMMARY_PROMPT
  end
end
```

#### 2c. Chat Model -- System Prompt Modification

- [ ] Add cross-conversation context to `system_message_for`
- [ ] Add borrowed context consumption to `build_context_for_agent`

In `Chat#system_message_for(agent)`, add a new section before the final time/participant lines:

```ruby
def system_message_for(agent, initiation_reason: nil)
  parts = []

  # ... existing parts (system_prompt, memory_context, health, whiteboards, topic, etc.) ...

  if (cross_conv_context = cross_conversation_context_for(agent))
    parts << cross_conv_context
  end

  if (borrowed = borrowed_context_for(agent))
    parts << borrowed
  end

  # ... existing: dev warning, agent-only, initiation_reason, time, participants ...

  { role: "system", content: parts.join("\n\n") }
end
```

- [ ] Implement `cross_conversation_context_for(agent)` as a private method on Chat

```ruby
def cross_conversation_context_for(agent)
  other_chat_agents = ChatAgent
    .joins(:chat)
    .where(agent_id: agent.id)
    .where.not(chat_id: id)
    .where.not(agent_summary: [nil, ""])
    .where("chats.updated_at > ?", 6.hours.ago)
    .where("chats.discarded_at IS NULL")
    .includes(:chat)
    .order("chats.updated_at DESC")
    .limit(10)

  return nil if other_chat_agents.empty?

  lines = other_chat_agents.map do |ca|
    conv_id = ca.chat.obfuscated_id
    title = ca.chat.title_or_default
    "- [#{conv_id}] \"#{title}\": #{ca.agent_summary}"
  end

  "# Your Other Active Conversations\n\n" \
  "You are also participating in these conversations (updated in last 6 hours):\n\n" \
  "#{lines.join("\n")}\n\n" \
  "If any of these are relevant to the current discussion, you can use the borrow_context " \
  "tool with the conversation ID to pull in recent messages for reference."
end
```

- [ ] Implement `borrowed_context_for(agent)` as a private method on Chat

```ruby
def borrowed_context_for(agent)
  chat_agent = chat_agents.find_by(agent_id: agent.id)
  return nil unless chat_agent&.borrowed_context?

  borrowed = chat_agent.consume_borrowed_context!
  return nil if borrowed.blank?

  source_id = borrowed["source_conversation_id"]
  messages_text = borrowed["messages"].map do |m|
    "[#{m['author']}]: #{m['content']}"
  end.join("\n")

  "# Borrowed Context from Conversation #{source_id}\n\n" \
  "You requested context from another conversation. Here are the recent messages:\n\n" \
  "#{messages_text}\n\n" \
  "This context is provided for reference only and will not appear in future activations."
end
```

### 3. Background Job: GenerateAgentSummaryJob

- [ ] Create `app/jobs/generate_agent_summary_job.rb`

```ruby
class GenerateAgentSummaryJob < ApplicationJob
  queue_as :default

  def perform(chat, agent)
    chat_agent = ChatAgent.find_by(chat: chat, agent: agent)
    return unless chat_agent
    return unless chat_agent.summary_stale?

    recent_messages = chat.messages
      .where(role: %w[user assistant])
      .order(created_at: :desc)
      .limit(10)
      .reverse

    return if recent_messages.length < 2

    transcript = recent_messages.map do |m|
      author = m.agent&.name || m.user&.full_name || "User"
      "#{author}: #{m.content.to_s.truncate(500)}"
    end

    prompt = Prompt.new(model: Prompt::LIGHT_MODEL, template: "generate_agent_summary")
    prompt.render(
      identity: agent.system_prompt.presence || "You are #{agent.name}.",
      summary_instructions: agent.effective_summary_prompt,
      previous_summary: chat_agent.agent_summary,
      messages: transcript,
      conversation_title: chat.title_or_default
    )

    new_summary = prompt.execute_to_string&.squish&.truncate(500)

    if new_summary.present?
      chat_agent.update_columns(
        agent_summary: new_summary,
        agent_summary_generated_at: Time.current
      )
    end
  rescue StandardError => e
    Rails.logger.error "Agent summary generation failed for chat=#{chat.id} agent=#{agent.id}: #{e.message}"
  end
end
```

### 4. Prompt Template: generate_agent_summary

- [ ] Create `app/prompts/generate_agent_summary/system.prompt.erb`

```erb
<%= summary_instructions %>

Your identity:
<%= identity %>

<% if previous_summary.present? %>
Your previous summary of this conversation:
<%= previous_summary %>

Update this summary based on the latest messages. Keep exactly 2 lines.
<% end %>

Respond with the summary text only. No labels, no bullet points, no prefixes.
```

- [ ] Create `app/prompts/generate_agent_summary/user.prompt.erb`

```erb
Conversation: "<%= conversation_title %>"

Recent messages:

<% messages.each do |line| %>
- <%= line %>
<% end %>
```

### 5. Triggering Summary Generation

- [ ] Hook into message creation to trigger summary generation

The cleanest approach: add an `after_create_commit` callback on `Message` that enqueues summary jobs for all agents in the conversation.

In `Message`:

```ruby
after_create_commit :queue_agent_summaries, if: -> { role.in?(%w[user assistant]) && content.present? }

private

def queue_agent_summaries
  chat.agents.find_each do |agent|
    GenerateAgentSummaryJob.perform_later(chat, agent)
  end
end
```

The debounce check happens inside the job (checking `summary_stale?`), so this is safe to call frequently. SolidQueue will handle the fan-out efficiently. No work is done if the summary was generated less than 5 minutes ago.

### 6. BorrowContextTool

- [ ] Create `app/tools/borrow_context_tool.rb`

```ruby
class BorrowContextTool < RubyLLM::Tool

  description "Borrow recent messages from another conversation you participate in. " \
              "The messages will be included in your system context for your next response " \
              "in the current conversation. Use the conversation ID from your active conversations list."

  param :conversation_id, type: :string,
        desc: "The conversation ID to borrow context from (from your active conversations list)",
        required: true

  param :compressed, type: :boolean,
        desc: "If true, summarize the messages instead of including them verbatim (saves tokens)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(conversation_id:, compressed: false)
    return error("Requires chat and agent context") unless @current_agent && @chat

    source_chat = find_source_chat(conversation_id)
    return error("Conversation not found or you are not a participant") unless source_chat
    return error("Cannot borrow from the current conversation") if source_chat.id == @chat.id

    recent_messages = source_chat.messages
      .where(role: %w[user assistant])
      .order(created_at: :desc)
      .limit(10)
      .includes(:agent, :user)
      .reverse

    return error("No messages found in that conversation") if recent_messages.empty?

    formatted = recent_messages.map do |m|
      {
        "author" => m.agent&.name || m.user&.full_name || "User",
        "content" => m.content.to_s.truncate(2000),
        "timestamp" => m.created_at.iso8601
      }
    end

    if compressed
      formatted = compress_messages(formatted, source_chat)
    end

    chat_agent = ChatAgent.find_by(chat: @chat, agent: @current_agent)
    chat_agent.update!(
      borrowed_context_json: {
        "source_conversation_id" => source_chat.obfuscated_id,
        "source_title" => source_chat.title_or_default,
        "messages" => formatted,
        "compressed" => compressed,
        "borrowed_at" => Time.current.iso8601
      }
    )

    {
      success: true,
      message: "Context from \"#{source_chat.title_or_default}\" will be included in your " \
               "system prompt for your next response in this conversation.",
      message_count: formatted.is_a?(Array) ? formatted.length : 1,
      compressed: compressed
    }
  end

  private

  def find_source_chat(conversation_id)
    decoded_id = Chat.decode_id(conversation_id)
    return nil unless decoded_id

    ChatAgent.find_by(
      agent_id: @current_agent.id,
      chat_id: decoded_id
    )&.chat
  end

  def compress_messages(formatted_messages, source_chat)
    transcript = formatted_messages.map do |m|
      "#{m['author']}: #{m['content']}"
    end.join("\n")

    prompt = Prompt.new(model: Prompt::LIGHT_MODEL, template: "compress_context")
    prompt.render(
      conversation_title: source_chat.title_or_default,
      transcript: transcript
    )

    compressed_text = prompt.execute_to_string&.squish
    return formatted_messages if compressed_text.blank?

    [{ "author" => "Summary", "content" => compressed_text }]
  rescue StandardError => e
    Rails.logger.error "Context compression failed: #{e.message}"
    formatted_messages
  end

  def error(msg) = { error: msg }

end
```

### 7. Prompt Template: compress_context

- [ ] Create `app/prompts/compress_context/system.prompt.erb`

```erb
You are compressing a conversation transcript for quick reference.
Preserve the key information, decisions, and current state.
Keep the flow of the exchange visible (who said what) but be concise.
Aim for about 30% of the original length.
Respond with the compressed transcript only.
```

- [ ] Create `app/prompts/compress_context/user.prompt.erb`

```erb
Conversation: "<%= conversation_title %>"

Transcript to compress:

<%= transcript %>
```

### 8. Controller and Frontend Changes

#### 8a. AgentsController

- [ ] Add `summary_prompt` to permitted params

```ruby
def agent_params
  params.require(:agent).permit(
    :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
    :summary_prompt,
    :model_id, :active, :colour, :icon,
    :thinking_enabled, :thinking_budget,
    :telegram_bot_username, :telegram_bot_token,
    enabled_tools: []
  )
end
```

#### 8b. Agent Edit Page (Svelte)

- [ ] Add `summary_prompt` field to the identity tab in `app/frontend/pages/agents/edit.svelte`

Add to the form initialization:

```javascript
let form = useForm({
  agent: {
    // ... existing fields ...
    summary_prompt: agent.summary_prompt || '',
  },
});
```

Add to the identity tab section (after the memory_reflection_prompt textarea):

```svelte
<div class="space-y-2">
  <Label for="summary_prompt">Summary Prompt</Label>
  <textarea
    id="summary_prompt"
    bind:value={$form.agent.summary_prompt}
    placeholder="Leave empty to use default summary prompt (focus on state, 2 lines)"
    rows="6"
    class="w-full resize-none border border-input rounded-md px-3 py-2 text-sm bg-background font-mono
           focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent"></textarea>
  <p class="text-xs text-muted-foreground">
    Customize how this agent summarizes conversations for cross-conversation awareness.
    Leave empty to use the default prompt that focuses on current state rather than narrative.
  </p>
</div>
```

#### 8c. Agent Validation

- [ ] Add validation for `summary_prompt` length in `Agent` model (already shown above in 2b)

### 9. Wire Up the Tool

The `BorrowContextTool` will automatically appear in the tools list because it follows the `*_tool.rb` naming convention in `app/tools/`. Agents need it added to their `enabled_tools` to use it.

No additional wiring needed beyond the existing tool registration mechanism.

---

## Key Design Decisions

### Per-agent summaries vs shared summaries

The existing `Chat#summary` is a shared, third-person summary for the API. The new per-agent summaries are first-person, reflecting each agent's perspective and priorities. They live on `ChatAgent` to avoid any interference.

### Borrowed context in system prompt vs tool response

Returning context as a tool response means it enters the conversation history permanently, inflating token usage on every subsequent message. Injecting it into the system prompt for one activation only keeps the conversation lean. The trade-off is that the agent must act on the borrowed context immediately, which matches the intended use case.

### Debounce at job level vs callback level

The `after_create_commit` fires for every message, but the job checks `summary_stale?` and exits early if within cooldown. This is simpler than conditional callback logic and lets SolidQueue handle deduplication naturally. The cost of a no-op job is negligible.

### 10-conversation limit on cross-conversation context

The query limits to 10 recent conversations to bound system prompt growth. At ~100 tokens per summary (2 lines + metadata), this adds at most ~1,000 tokens to the system prompt -- manageable overhead.

### Compressed mode for BorrowContextTool

When `compressed: true`, the 10 messages are first run through a fast model to create a condensed summary. This trades fidelity for token economy. The compression happens synchronously within the tool execution since it must complete before the tool response.

---

## Testing Strategy

### Unit Tests

- [ ] `test/models/chat_agent_test.rb`
  - `summary_stale?` returns true when no summary exists
  - `summary_stale?` returns true after 5 minutes
  - `summary_stale?` returns false within 5 minutes
  - `consume_borrowed_context!` returns and clears the context
  - `consume_borrowed_context!` returns nil when no context exists

- [ ] `test/models/agent_test.rb`
  - `effective_summary_prompt` returns custom prompt when set
  - `effective_summary_prompt` returns default when blank
  - Validates `summary_prompt` length

- [ ] `test/models/chat_test.rb`
  - `cross_conversation_context_for(agent)` returns nil when no other conversations
  - `cross_conversation_context_for(agent)` excludes current conversation
  - `cross_conversation_context_for(agent)` excludes conversations older than 6 hours
  - `cross_conversation_context_for(agent)` excludes discarded conversations
  - `cross_conversation_context_for(agent)` formats summaries with obfuscated IDs
  - `borrowed_context_for(agent)` returns nil when no borrowed context
  - `borrowed_context_for(agent)` formats and consumes borrowed context

### Job Tests

- [ ] `test/jobs/generate_agent_summary_job_test.rb`
  - Generates summary when stale
  - Skips when not stale (debounce)
  - Skips when fewer than 2 messages
  - Updates `agent_summary` and `agent_summary_generated_at`
  - Handles LLM errors gracefully

### Tool Tests

- [ ] `test/tools/borrow_context_tool_test.rb`
  - Returns error without agent context
  - Returns error for non-participating conversation
  - Returns error for current conversation
  - Returns error for non-existent conversation ID
  - Stores context on ChatAgent for next activation
  - Compressed mode summarizes before storing
  - Formats messages correctly

### Integration Tests

- [ ] Verify end-to-end: message -> summary job -> system prompt includes summary
- [ ] Verify end-to-end: borrow tool -> next activation includes context -> subsequent activation does not

---

## Edge Cases and Error Handling

| Scenario | Handling |
|----------|----------|
| Agent removed from conversation after summary generated | Summary remains on orphaned ChatAgent record; `cross_conversation_context_for` only queries active ChatAgents |
| Borrowed context from a conversation that gets deleted | Context was already staged as JSON; it will be included once then cleared regardless of source state |
| LLM failure during summary generation | Caught and logged; existing summary preserved; retried on next message |
| LLM failure during context compression | Falls back to returning uncompressed messages |
| Very long messages in borrowed context | Truncated to 2,000 chars per message in the tool |
| Agent has no other conversations | `cross_conversation_context_for` returns nil; no section added to prompt |
| Race condition: two messages trigger summary simultaneously | Both jobs check `summary_stale?`; worst case is two summaries generated, last writer wins; acceptable |
| Borrowed context set but agent never activated again | Context persists in `borrowed_context_json` until the next activation or forever; low cost (single JSON column) |

---

## Files to Create or Modify

### New Files
- `db/migrate/XXXXXX_add_multi_threaded_thinking_fields.rb`
- `app/jobs/generate_agent_summary_job.rb`
- `app/tools/borrow_context_tool.rb`
- `app/prompts/generate_agent_summary/system.prompt.erb`
- `app/prompts/generate_agent_summary/user.prompt.erb`
- `app/prompts/compress_context/system.prompt.erb`
- `app/prompts/compress_context/user.prompt.erb`
- `test/jobs/generate_agent_summary_job_test.rb`
- `test/tools/borrow_context_tool_test.rb`

### Modified Files
- `app/models/chat_agent.rb` -- summary/borrowed context methods
- `app/models/agent.rb` -- `summary_prompt` field, validation, default prompt, `json_attributes`
- `app/models/chat.rb` -- `cross_conversation_context_for`, `borrowed_context_for`, modifications to `system_message_for` and `build_context_for_agent`
- `app/models/message.rb` -- `after_create_commit :queue_agent_summaries`
- `app/controllers/agents_controller.rb` -- permit `summary_prompt`
- `app/frontend/pages/agents/edit.svelte` -- summary prompt textarea
- `test/models/chat_agent_test.rb` -- new tests
- `test/models/agent_test.rb` -- new tests
- `test/models/chat_test.rb` -- new tests
