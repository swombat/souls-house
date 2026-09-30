# Multi-Threaded Thinking: Cross-Conversation Awareness (Revision B)

## Executive Summary

Give agents awareness of their other active conversations by injecting short summaries into the system prompt, and let them pull full context from another conversation on demand via a new `BorrowContextTool`. Summaries are per-agent, debounced per-conversation, and generated asynchronously. Borrowed context is ephemeral -- included in the system prompt for exactly one activation, then cleared after the response succeeds.

This revision incorporates DHH's code review feedback: no `summary_prompt` on Agent (summary instructions are inlined in the prompt template), no `compressed` mode on BorrowContextTool, leaner `borrowed_context_json` structure, cross-conversation query moved to Agent, debounce checked before enqueuing, and borrowed context consumed after the LLM response completes rather than during prompt assembly.

Three components:

1. **Per-agent conversation summaries** stored on `ChatAgent`, generated via background job with 5-minute per-conversation debounce
2. **Cross-conversation context block** appended to the system prompt via `Agent#other_conversation_summaries`
3. **BorrowContextTool** that stages messages from another conversation into the system prompt for a single activation

---

## Architecture Overview

### Why summaries live on ChatAgent, not Chat

Different agents see the same conversation differently. A security-focused agent emphasizes different aspects than a creative writing agent. The agent's `system_prompt` already provides identity context -- when that identity is passed into the summary generation prompt template, the agent naturally produces identity-flavored summaries. No separate `summary_prompt` field needed.

The existing `Chat#summary` and `Chat#summary_generated_at` columns serve a different purpose (API-facing, third-person summaries). These remain untouched.

### Data Flow

```
Message created
  -> after_create_commit: check each ChatAgent's summary_stale?
     -> Only enqueue GenerateAgentSummaryJob for stale ones
  -> Job generates 2-line summary via Prompt with agent's system_prompt as identity
  -> Stores on ChatAgent#agent_summary, ChatAgent#agent_summary_generated_at

Agent responds in any conversation
  -> Chat#system_message_for(agent) builds system prompt
  -> Calls agent.other_conversation_summaries(exclude_chat_id: id)
  -> Formats and appends "# Your Other Conversations" block
  -> Reads (but does NOT consume) any borrowed_context_json

Agent calls BorrowContextTool
  -> Tool sets ChatAgent#borrowed_context_json on current ChatAgent
  -> Next activation: system prompt includes borrowed messages
  -> After LLM response succeeds: on_end_message clears borrowed_context_json

LLM response fails
  -> borrowed_context_json remains intact for retry
```

### Key Design Change: Consume After Success

The first iteration consumed borrowed context during prompt assembly (`consume_borrowed_context!` inside `system_message_for`). If the LLM call failed after context was built but before the response completed, the borrowed context was lost forever.

This revision reads the context during prompt assembly but only clears it after the response succeeds. The clearing happens in `on_end_message` in both `ManualAgentResponseJob` and `AllAgentsResponseJob`. If the job retries, the borrowed context is still there.

---

## Step-by-Step Implementation

### 1. Database Migration

- [ ] Create migration `AddMultiThreadedThinkingFields`

```ruby
class AddMultiThreadedThinkingFields < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_agents, :agent_summary, :text
    add_column :chat_agents, :agent_summary_generated_at, :datetime
    add_column :chat_agents, :borrowed_context_json, :jsonb

    add_index :chat_agents, [:agent_id, :agent_summary_generated_at],
              name: "index_chat_agents_on_agent_summary_recency"
  end
end
```

| Column | Table | Type | Purpose |
|--------|-------|------|---------|
| `agent_summary` | `chat_agents` | `text` | This agent's 2-line summary of this conversation |
| `agent_summary_generated_at` | `chat_agents` | `datetime` | Debounce timestamp |
| `borrowed_context_json` | `chat_agents` | `jsonb` | Staged messages for next activation (cleared after success) |

No changes to the `agents` table. No `summary_prompt` column.

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

  def clear_borrowed_context!
    update_columns(borrowed_context_json: nil) if borrowed_context_json.present?
  end
end
```

The model stays minimal. `summary_stale?` is the debounce gate. `clear_borrowed_context!` is called after the LLM response succeeds. Reading `borrowed_context_json` directly is sufficient -- no wrapper method needed.

#### 2b. Agent Model

- [ ] Add `other_conversation_summaries` query method to `Agent`

```ruby
class Agent < ApplicationRecord
  # ... existing code ...

  def other_conversation_summaries(exclude_chat_id:)
    chat_agents
      .joins(:chat)
      .where.not(chat_id: exclude_chat_id)
      .where.not(agent_summary: [nil, ""])
      .where("chats.updated_at > ?", 6.hours.ago)
      .where("chats.discarded_at IS NULL")
      .includes(:chat)
      .order("chats.updated_at DESC")
      .limit(10)
  end
end
```

This follows the existing pattern: `Agent#memory_context` builds agent-centric context, and `system_message_for` assembles the parts. The query lives on Agent because it queries the agent's own conversations. The formatting stays on Chat (it knows about prompt structure).

#### 2c. Chat Model -- System Prompt Modification

- [ ] Add cross-conversation and borrowed context sections to `system_message_for`

In `Chat#system_message_for(agent)`, add two new sections before the time/participant lines:

```ruby
def system_message_for(agent, initiation_reason: nil)
  parts = []

  # ... existing parts (system_prompt, memory_context, health, whiteboards, topic, etc.) ...

  if (cross_conv = format_cross_conversation_context(agent))
    parts << cross_conv
  end

  if (borrowed = format_borrowed_context(agent))
    parts << borrowed
  end

  # ... existing: dev warning, agent-only, initiation_reason, time, participants ...

  { role: "system", content: parts.join("\n\n") }
end
```

- [ ] Implement `format_cross_conversation_context` as a private method on Chat

```ruby
def format_cross_conversation_context(agent)
  summaries = agent.other_conversation_summaries(exclude_chat_id: id)
  return nil if summaries.empty?

  lines = summaries.map do |ca|
    "- [#{ca.chat.obfuscated_id}] \"#{ca.chat.title_or_default}\": #{ca.agent_summary}"
  end

  "# Your Other Active Conversations\n\n" \
  "You are also participating in these conversations (updated in last 6 hours):\n\n" \
  "#{lines.join("\n")}\n\n" \
  "If any of these are relevant to the current discussion, you can use the borrow_context " \
  "tool with the conversation ID to pull in recent messages for reference."
end
```

- [ ] Implement `format_borrowed_context` as a private method on Chat

This method reads but does NOT clear the borrowed context. Clearing happens after the LLM response succeeds (see section 8).

```ruby
def format_borrowed_context(agent)
  chat_agent = chat_agents.find_by(agent_id: agent.id)
  borrowed = chat_agent&.borrowed_context_json
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

Identity first, then task instructions (inlined, no configurable prompt):

```erb
Your identity:
<%= identity %>

Summarize this conversation for your own reference. Focus on current state:
- What is being worked on right now?
- What decisions are pending?
- What has been agreed or resolved?

Do NOT narrate what happened. Describe where things stand. Write exactly 2 lines.

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

- [ ] Hook into message creation with callback-level debounce

In `Message`, add an `after_create_commit` that checks `summary_stale?` before enqueuing to avoid no-op jobs:

```ruby
after_create_commit :queue_agent_summaries, if: -> { role.in?(%w[user assistant]) && content.present? }

private

def queue_agent_summaries
  chat.chat_agents.each do |chat_agent|
    next unless chat_agent.summary_stale?
    GenerateAgentSummaryJob.perform_later(chat, chat_agent.agent)
  end
end
```

The job still checks `summary_stale?` as a safety net for race conditions, but the callback avoids enqueuing jobs that will immediately exit. In a group chat with 4 agents where summaries were generated 2 minutes ago, this enqueues zero jobs instead of four.

### 6. BorrowContextTool

- [ ] Create `app/tools/borrow_context_tool.rb`

No `compressed` parameter. No compression logic. No extra prompt templates.

```ruby
class BorrowContextTool < RubyLLM::Tool

  description "Borrow recent messages from another conversation you participate in. " \
              "The messages will be included in your system context for your next response " \
              "in the current conversation. Use the conversation ID from your active conversations list."

  param :conversation_id, type: :string,
        desc: "The conversation ID to borrow context from (from your active conversations list)",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(conversation_id:)
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
        "content" => m.content.to_s.truncate(2000)
      }
    end

    chat_agent = ChatAgent.find_by(chat: @chat, agent: @current_agent)
    chat_agent.update!(
      borrowed_context_json: {
        "source_conversation_id" => source_chat.obfuscated_id,
        "messages" => formatted
      }
    )

    {
      success: true,
      message: "Context from \"#{source_chat.title_or_default}\" will be included in your " \
               "system prompt for your next response in this conversation.",
      message_count: formatted.length
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

  def error(msg) = { error: msg }

end
```

### 7. No compress_context prompt template

Removed entirely per DHH's feedback. 10 messages at 2,000 characters each is at most 20,000 characters -- well within any model's context window. If token economy becomes a problem later, add compression then.

### 8. Consuming Borrowed Context After Success

- [ ] Modify `ManualAgentResponseJob` and `AllAgentsResponseJob` to clear borrowed context on success

In both jobs, add a `clear_borrowed_context!` call inside the `on_end_message` callback. This ensures the context is only cleared after the LLM response completes successfully. If the job fails and retries, the borrowed context remains available.

In `ManualAgentResponseJob#perform`:

```ruby
llm.on_end_message do |msg|
  debug_info "Response complete - #{msg.content&.length || 0} chars"
  finalize_message!(msg)
  @agent.notify_subscribers!(@ai_message, @chat) if @ai_message&.persisted? && initiation_reason.present?

  ChatAgent.find_by(chat: @chat, agent: @agent)&.clear_borrowed_context!
end
```

In `AllAgentsResponseJob#perform`, the same pattern:

```ruby
llm.on_end_message do |msg|
  debug_info "Response complete - #{msg.content&.length || 0} chars"
  finalize_message!(msg)

  ChatAgent.find_by(chat: @chat, agent: agent)&.clear_borrowed_context!
end
```

This is a single line added to each job. The `clear_borrowed_context!` method is a no-op if there is no borrowed context (it checks `present?` before updating).

### 9. Wire Up the Tool

The `BorrowContextTool` will automatically appear in the tools list because it follows the `*_tool.rb` naming convention in `app/tools/`. Agents need it added to their `enabled_tools` to use it.

No additional wiring needed beyond the existing tool registration mechanism.

---

## Key Design Decisions

### No summary_prompt on Agent

The agent's `system_prompt` already defines its identity. When passed as the `identity` variable to the summary generation prompt, it naturally produces identity-flavored summaries. The summary task instructions ("focus on state, 2 lines") are task instructions, not identity -- they belong in the prompt template. This eliminates a database column, validation, method, constant, form field, controller change, and test cases.

### No compressed mode on BorrowContextTool

The uncompressed path sends 10 messages truncated to 2,000 characters each -- at most 20,000 characters, well within any model's context window. Adding compression introduces a synchronous LLM call inside tool execution, two prompt templates, error handling with fallback, and conditional branching. All for a feature that may never be needed. Ship without it.

### Per-agent summaries vs shared summaries

The existing `Chat#summary` is a shared, third-person summary for the API. The new per-agent summaries are first-person, reflecting each agent's perspective and priorities. They live on `ChatAgent` to avoid interference.

### Borrowed context in system prompt vs tool response

Returning context as a tool response means it enters the conversation history permanently, inflating token usage on every subsequent message. Injecting it into the system prompt for one activation keeps the conversation lean. The trade-off is that the agent must act on the borrowed context immediately, which matches the intended use case.

### Read-then-clear pattern for borrowed context

The prompt builder reads `borrowed_context_json` but does not clear it. The `on_end_message` callback clears it after success. This means:
- If the LLM call fails, the context survives for retry
- If the agent calls the tool again before the context is consumed, the new context replaces the old one (last writer wins, which is fine)
- The worst case is a stale context sitting in the JSON column indefinitely if the agent is never activated again (negligible cost)

### Debounce at callback level AND job level

The callback checks `summary_stale?` before enqueuing, avoiding unnecessary SolidQueue records. The job re-checks as a safety net for race conditions. Belt and suspenders, both cheap.

### Cross-conversation query on Agent

`Agent#other_conversation_summaries(exclude_chat_id:)` follows the pattern of `Agent#memory_context`. The agent knows about its own conversations. Chat knows about prompt assembly. Clean separation.

---

## Testing Strategy

### Unit Tests

- [ ] `test/models/chat_agent_test.rb`
  - `summary_stale?` returns true when no summary exists
  - `summary_stale?` returns true after 5 minutes
  - `summary_stale?` returns false within 5 minutes
  - `clear_borrowed_context!` clears the JSON column
  - `clear_borrowed_context!` is a no-op when no context exists

- [ ] `test/models/agent_test.rb`
  - `other_conversation_summaries` returns summaries from other conversations
  - `other_conversation_summaries` excludes the specified chat
  - `other_conversation_summaries` excludes conversations older than 6 hours
  - `other_conversation_summaries` excludes discarded conversations
  - `other_conversation_summaries` excludes blank summaries
  - `other_conversation_summaries` limits to 10 results

- [ ] `test/models/chat_test.rb`
  - `format_cross_conversation_context` returns nil when no other conversations
  - `format_cross_conversation_context` formats summaries with obfuscated IDs
  - `format_borrowed_context` returns nil when no borrowed context
  - `format_borrowed_context` formats messages without consuming them

### Job Tests

- [ ] `test/jobs/generate_agent_summary_job_test.rb`
  - Generates summary when stale
  - Skips when not stale (debounce)
  - Skips when fewer than 2 messages
  - Updates `agent_summary` and `agent_summary_generated_at`
  - Handles LLM errors gracefully (logs, does not raise)

### Tool Tests

- [ ] `test/tools/borrow_context_tool_test.rb`
  - Returns error without agent context
  - Returns error for non-participating conversation
  - Returns error for current conversation
  - Returns error for non-existent conversation ID
  - Returns error for conversation with no messages
  - Stores minimal JSON on ChatAgent (`source_conversation_id` + `messages` only)
  - Formats messages with author and truncated content

### Integration Tests

- [ ] Verify end-to-end: message -> summary job (debounced) -> system prompt includes summary
- [ ] Verify end-to-end: borrow tool -> next activation includes context -> on_end_message clears context -> subsequent activation does not include it

---

## Edge Cases and Error Handling

| Scenario | Handling |
|----------|----------|
| Agent removed from conversation after summary generated | Summary remains on orphaned ChatAgent record; `other_conversation_summaries` only queries active ChatAgents |
| Borrowed context from a conversation that gets deleted | Context was already staged as JSON; it will be included once then cleared regardless of source state |
| LLM failure during summary generation | Caught and logged; existing summary preserved; retried on next message after cooldown |
| LLM failure after borrowed context read into prompt | Context is NOT cleared; remains available for retry |
| Very long messages in borrowed context | Truncated to 2,000 chars per message in the tool |
| Agent has no other conversations | `other_conversation_summaries` returns empty relation; no section added to prompt |
| Race condition: two messages trigger summary simultaneously | Callback checks `summary_stale?`; at most one job enqueued; job re-checks as safety net |
| Borrowed context set but agent never activated again | Context persists in `borrowed_context_json` indefinitely; single JSON column, negligible cost |
| Tool called twice before activation | Second call overwrites first; last writer wins; acceptable |

---

## Files to Create or Modify

### New Files
- `db/migrate/XXXXXX_add_multi_threaded_thinking_fields.rb`
- `app/jobs/generate_agent_summary_job.rb`
- `app/tools/borrow_context_tool.rb`
- `app/prompts/generate_agent_summary/system.prompt.erb`
- `app/prompts/generate_agent_summary/user.prompt.erb`
- `test/jobs/generate_agent_summary_job_test.rb`
- `test/tools/borrow_context_tool_test.rb`

### Modified Files
- `app/models/chat_agent.rb` -- `summary_stale?`, `clear_borrowed_context!`
- `app/models/agent.rb` -- `other_conversation_summaries(exclude_chat_id:)`
- `app/models/chat.rb` -- `format_cross_conversation_context`, `format_borrowed_context`, additions to `system_message_for`
- `app/models/message.rb` -- `after_create_commit :queue_agent_summaries`
- `app/jobs/manual_agent_response_job.rb` -- `clear_borrowed_context!` in `on_end_message`
- `app/jobs/all_agents_response_job.rb` -- `clear_borrowed_context!` in `on_end_message`
- `test/models/chat_agent_test.rb` -- new tests
- `test/models/agent_test.rb` -- new tests
- `test/models/chat_test.rb` -- new tests

---

## What Changed from Revision A

| Item | Revision A | Revision B |
|------|-----------|-----------|
| `summary_prompt` on Agent | Column, validation, method, constant, form field, controller param | Removed entirely |
| `compressed` mode on BorrowContextTool | Parameter, private method, 2 prompt templates, fallback logic | Removed entirely |
| `borrowed_context_json` structure | 5 keys (source_id, title, messages, compressed, borrowed_at) | 2 keys (source_conversation_id, messages) |
| Cross-conversation query | `Chat#cross_conversation_context_for(agent)` | `Agent#other_conversation_summaries(exclude_chat_id:)` |
| Summary job enqueue | Callback fans out blindly, debounce only in job | Callback checks `summary_stale?` before enqueuing |
| Borrowed context consumption | Consumed during prompt assembly (data loss risk on failure) | Read during prompt assembly, cleared in `on_end_message` after success |
| Prompt template ordering | Summary instructions first, then identity | Identity first, then task instructions |
| Summary instructions | Configurable via `effective_summary_prompt` | Inlined directly in the prompt template |
| Files created | 9 new files | 7 new files |
| Files modified | 8 files | 8 files |
