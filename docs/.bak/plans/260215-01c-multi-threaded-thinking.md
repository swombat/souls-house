# Multi-Threaded Thinking: Cross-Conversation Awareness (Final)

## Executive Summary

Give agents awareness of their other active conversations by injecting short summaries into the system prompt, and let them pull full context from another conversation on demand via a new `BorrowContextTool`. Summaries are per-agent, debounced per-conversation, and generated asynchronously. Borrowed context is ephemeral -- included in the system prompt for exactly one activation, then cleared after the response succeeds.

Three components:

1. **Per-agent conversation summaries** stored on `ChatAgent`, generated via background job with 5-minute per-conversation debounce
2. **Cross-conversation context block** appended to the system prompt via `Agent#other_conversation_summaries`
3. **BorrowContextTool** that stages messages from another conversation into the system prompt for a single activation

---

## Architecture Overview

### Why summaries live on ChatAgent, not Chat

Different agents see the same conversation differently. A security-focused agent emphasizes different aspects than a creative writing agent. The agent's `system_prompt` provides identity context, and a separate `summary_prompt` lets each agent customize how they summarize conversations — following the same pattern as `reflection_prompt` and `memory_reflection_prompt`.

The existing `Chat#summary` and `Chat#summary_generated_at` columns serve a different purpose (API-facing, third-person summaries). These remain untouched.

### Data Flow

```
Message created
  -> after_create_commit: check each ChatAgent's summary_stale?
     -> Only enqueue GenerateAgentSummaryJob for stale ones
  -> Job generates 2-line summary via Prompt with agent's summary_prompt + system_prompt as identity
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

### Consume After Success

The prompt builder reads borrowed context during assembly but only clears it after the response succeeds. The clearing happens in `on_end_message` in both `ManualAgentResponseJob` and `AllAgentsResponseJob`, and MUST be called after `finalize_message!` completes. If the job retries, the borrowed context is still there.

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

    # Per-agent summary identity prompt (like reflection_prompt, memory_reflection_prompt)
    add_column :agents, :summary_prompt, :text
  end
end
```

| Column | Table | Type | Purpose |
|--------|-------|------|---------|
| `agent_summary` | `chat_agents` | `text` | This agent's 2-line summary of this conversation |
| `agent_summary_generated_at` | `chat_agents` | `datetime` | Debounce timestamp |
| `borrowed_context_json` | `chat_agents` | `jsonb` | Staged messages for next activation (cleared after success) |
| `summary_prompt` | `agents` | `text` | Custom identity prompt for summary generation (like reflection_prompt) |

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

- [ ] Add `summary_prompt` validation, json_attributes, default, and `other_conversation_summaries`

```ruby
class Agent < ApplicationRecord
  # ... existing validations ...
  validates :summary_prompt, length: { maximum: 10_000 }

  # Add :summary_prompt to the existing json_attributes line:
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

  def other_conversation_summaries(exclude_chat_id:)
    chat_agents
      .joins(:chat)
      .where.not(chat_id: exclude_chat_id)
      .where.not(agent_summary: [nil, ""])
      .where("chats.updated_at > ?", 6.hours.ago)
      .merge(Chat.kept)
      .includes(:chat)
      .order("chats.updated_at DESC")
      .limit(10)
  end
end
```

Uses `merge(Chat.kept)` to leverage the discard gem's scope rather than raw SQL. This follows the existing pattern: `Agent#memory_context` builds agent-centric context, `Agent#effective_summary_prompt` provides the customizable identity prompt (like `reflection_prompt`), and `system_message_for` assembles the parts. The query lives on Agent because it queries the agent's own conversations. The formatting stays on Chat (it knows about prompt structure).

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
  rescue Faraday::Error, RubyLLM::Error => e
    Rails.logger.error "Agent summary generation failed for chat=#{chat.id} agent=#{agent.id}: #{e.message}"
  end
end
```

The rescue narrows to `Faraday::Error` (network issues) and `RubyLLM::Error` (LLM API issues). Genuine bugs in the transcript building or database access will raise normally and surface in error tracking.

### 4. Prompt Template: generate_agent_summary

- [ ] Create `app/prompts/generate_agent_summary/system.prompt.erb`

Identity first, then summary instructions (from `agent.effective_summary_prompt`):

```erb
Your identity:
<%= identity %>

<%= summary_instructions %>

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

### 7. Consuming Borrowed Context After Success

- [ ] Modify `ManualAgentResponseJob` and `AllAgentsResponseJob` to clear borrowed context on success

In both jobs, add a `clear_borrowed_context!` call as the **last action** inside the `on_end_message` callback. This ordering is critical: `finalize_message!` must complete first so that if it raises, the borrowed context survives for retry. Only after all other `on_end_message` work has succeeded do we clear the borrowed context.

In `ManualAgentResponseJob#perform`:

```ruby
llm.on_end_message do |msg|
  debug_info "Response complete - #{msg.content&.length || 0} chars"
  finalize_message!(msg)
  @agent.notify_subscribers!(@ai_message, @chat) if @ai_message&.persisted? && initiation_reason.present?

  # Clear after finalize_message! succeeds -- if finalize raises, context survives for retry
  ChatAgent.find_by(chat: @chat, agent: @agent)&.clear_borrowed_context!
end
```

In `AllAgentsResponseJob#perform`, the same pattern:

```ruby
llm.on_end_message do |msg|
  debug_info "Response complete - #{msg.content&.length || 0} chars"
  finalize_message!(msg)

  # Clear after finalize_message! succeeds -- if finalize raises, context survives for retry
  ChatAgent.find_by(chat: @chat, agent: agent)&.clear_borrowed_context!
end
```

The `clear_borrowed_context!` method is a no-op if there is no borrowed context (it checks `present?` before updating).

### 8. Controller and Frontend Changes

#### 8a. AgentsController

- [ ] Add `summary_prompt` to permitted params

```ruby
def agent_params
  params.require(:agent).permit(
    :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
    :summary_prompt,
    # ... rest unchanged
  )
end
```

#### 8b. Agent Edit Page (Svelte)

- [ ] Add `summary_prompt` field to the identity tab in `app/frontend/pages/agents/edit.svelte`

Add to the form initialization alongside the other prompts:

```javascript
summary_prompt: agent.summary_prompt || '',
```

Add a textarea after the `memory_reflection_prompt` field, following the same pattern:

```svelte
<div class="space-y-2">
  <Label for="summary_prompt">Summary Prompt</Label>
  <textarea
    id="summary_prompt"
    bind:value={$form.agent.summary_prompt}
    placeholder="Leave empty to use default (focus on state, 2 lines)"
    rows="6"
    class="...existing textarea classes..."></textarea>
  <p class="text-xs text-muted-foreground">
    Customize how this agent summarizes conversations for cross-conversation awareness.
    Leave empty for the default prompt that focuses on current state rather than narrative.
  </p>
</div>
```

### 9. Wire Up the Tool

The `BorrowContextTool` will automatically appear in the tools list because it follows the `*_tool.rb` naming convention in `app/tools/`. Agents need it added to their `enabled_tools` to use it.

No additional wiring needed beyond the existing tool registration mechanism.

---

## Key Design Decisions

### Configurable summary_prompt on Agent

Follows the existing pattern of `reflection_prompt` and `memory_reflection_prompt` — a per-agent customizable identity prompt with a sensible default. The default encourages focusing on state rather than narrative, but agents can customize this to match how they want to track conversations. The agent's `system_prompt` provides identity context separately via the `identity` variable in the prompt template.

### No compressed mode on BorrowContextTool

The uncompressed path sends 10 messages truncated to 2,000 characters each -- at most 20,000 characters, well within any model's context window. Adding compression introduces a synchronous LLM call inside tool execution, two prompt templates, error handling with fallback, and conditional branching. All for a feature that may never be needed. Ship without it.

### Per-agent summaries vs shared summaries

The existing `Chat#summary` is a shared, third-person summary for the API. The new per-agent summaries are first-person, reflecting each agent's perspective and priorities. They live on `ChatAgent` to avoid interference.

### Borrowed context in system prompt vs tool response

Returning context as a tool response means it enters the conversation history permanently, inflating token usage on every subsequent message. Injecting it into the system prompt for one activation keeps the conversation lean. The trade-off is that the agent must act on the borrowed context immediately, which matches the intended use case.

### Read-then-clear pattern for borrowed context

The prompt builder reads `borrowed_context_json` but does not clear it. The `on_end_message` callback clears it after success, always as the last action after `finalize_message!`. This means:
- If the LLM call fails, the context survives for retry
- If `finalize_message!` raises inside `on_end_message`, the context survives for retry
- If the agent calls the tool again before the context is consumed, the new context replaces the old one (last writer wins, which is fine)
- The worst case is a stale context sitting in the JSON column indefinitely if the agent is never activated again (negligible cost)

### Debounce at callback level AND job level

The callback checks `summary_stale?` before enqueuing, avoiding unnecessary SolidQueue records. The job re-checks as a safety net for race conditions. Belt and suspenders, both cheap.

### Cross-conversation query on Agent

`Agent#other_conversation_summaries(exclude_chat_id:)` follows the pattern of `Agent#memory_context`. The agent knows about its own conversations. Chat knows about prompt assembly. Clean separation.

### Narrowed rescue in GenerateAgentSummaryJob

The job rescues `Faraday::Error` and `RubyLLM::Error` -- the two error families that represent expected, transient failures (network issues and LLM API errors). A `NoMethodError` or `ActiveRecord::RecordNotFound` from a genuine bug in the summary-building code will raise normally and show up in error tracking, not be silently swallowed.

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
  - `effective_summary_prompt` returns custom prompt when set
  - `effective_summary_prompt` returns default when blank
  - Validates `summary_prompt` length
  - `other_conversation_summaries` returns summaries from other conversations and excludes the specified chat
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
  - Rescues LLM/network errors gracefully (logs, does not raise)
  - Does NOT rescue non-LLM errors (e.g., `NoMethodError` raises normally)

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
| LLM failure during summary generation | Caught by `rescue Faraday::Error, RubyLLM::Error`; existing summary preserved; retried on next message after cooldown |
| Non-LLM error during summary generation | Raises normally; surfaces in error tracking |
| LLM failure after borrowed context read into prompt | Context is NOT cleared; remains available for retry |
| `finalize_message!` raises inside `on_end_message` | Borrowed context is NOT cleared (it comes after finalize); remains available for retry |
| Very long messages in borrowed context | Truncated to 2,000 chars per message in the tool |
| Agent has no other conversations | `other_conversation_summaries` returns empty relation; no section added to prompt |
| Race condition: two messages trigger summary simultaneously | Callback checks `summary_stale?`; at most one job enqueued; job re-checks as safety net |
| Borrowed context set but agent never activated again | Context persists in `borrowed_context_json` indefinitely; single JSON column, negligible cost |
| Tool called twice before activation | Second call overwrites first; last writer wins; acceptable |
| Discarded conversations | Filtered out by `merge(Chat.kept)` in `other_conversation_summaries` |

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
- `app/models/agent.rb` -- `summary_prompt` validation, `json_attributes`, `DEFAULT_SUMMARY_PROMPT`, `effective_summary_prompt`, `other_conversation_summaries(exclude_chat_id:)`
- `app/models/chat.rb` -- `format_cross_conversation_context`, `format_borrowed_context`, additions to `system_message_for`
- `app/models/message.rb` -- `after_create_commit :queue_agent_summaries`
- `app/controllers/agents_controller.rb` -- permit `summary_prompt`
- `app/frontend/pages/agents/edit.svelte` -- summary prompt textarea on identity tab
- `app/jobs/manual_agent_response_job.rb` -- `clear_borrowed_context!` in `on_end_message`
- `app/jobs/all_agents_response_job.rb` -- `clear_borrowed_context!` in `on_end_message`
- `test/models/chat_agent_test.rb` -- new tests
- `test/models/agent_test.rb` -- new tests
- `test/models/chat_test.rb` -- new tests

---

## What Changed from Revision B

| Item | Revision B | Revision C (Final) |
|------|-----------|-------------------|
| `clear_borrowed_context!` ordering | Placed after `finalize_message!` in code but not called out | Explicitly documented: MUST be last action in `on_end_message`, with inline comment in code |
| `other_conversation_summaries` tests | 6 tests (returns + excludes current were separate) | 5 tests (merged into one that asserts both positive and negative) |
| Discarded chat filtering | `where("chats.discarded_at IS NULL")` raw SQL | `merge(Chat.kept)` using discard gem scope |
| `GenerateAgentSummaryJob` rescue | `rescue StandardError => e` (swallows all errors) | `rescue Faraday::Error, RubyLLM::Error => e` (only expected failures) |
