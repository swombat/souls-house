# Multi-Threaded Thinking: DHH-Style Review

## Overall Assessment

This is a well-structured spec that solves a real problem. The core idea -- give agents ambient awareness of their other conversations via summaries, plus an on-demand tool to pull full context -- is sound. The architecture mostly follows existing patterns in the codebase. But the spec over-engineers in a few places, introduces an unnecessary configuration surface (`summary_prompt` on Agent), and the `compressed` mode on BorrowContextTool is premature generalization. The borrowed context storage-and-consumption pattern is clever but adds mechanical complexity that deserves scrutiny.

---

## Critical Issues

### 1. `summary_prompt` is unnecessary configurability

The spec adds a `summary_prompt` column to agents, a `DEFAULT_SUMMARY_PROMPT` constant, an `effective_summary_prompt` method, a new form field, permitted params, and validation -- all so someone can customize how an agent summarizes conversations.

This is a textbook violation of YAGNI. The agent already has a `system_prompt` that defines its identity. The summary job already receives the agent's identity context. That is enough. A security-focused agent with a security-focused system prompt will naturally produce security-flavored summaries. You do not need a separate knob for this.

The requirements say "make the summary use a bespoke identity prompt like the other identity prompts." But `reflection_prompt` and `memory_reflection_prompt` exist because reflection and memory refinement are fundamentally different cognitive tasks from conversation. Summarization is not. A 2-line summary of recent messages does not need its own identity prompt. The default instructions ("focus on state, 2 lines") are task instructions, not identity -- they belong in the prompt template, not on the model.

**Recommendation**: Remove `summary_prompt` from Agent entirely. Remove the migration column, the validation, the `effective_summary_prompt` method, the form field, the controller params change. Put the summarization instructions directly in the prompt template where they belong. The agent's `system_prompt` already provides identity context via the `identity` variable passed to the job.

This removes: 1 database column, 1 validation, 1 method, 1 constant, 1 form field, 1 controller change, 3 test cases. That is a lot of complexity for zero practical benefit.

### 2. The `compressed` mode on BorrowContextTool is premature

The spec adds a `compressed` parameter, a `compress_messages` private method, an entire prompt template (`compress_context`), error handling for compression failure, a fallback path, and special-case logic in the JSON structure (`compressed` flag, array-vs-single check).

All of this for a feature the agent might use. The requirements say "add a setting to allow compressed context." But there is no evidence this is needed yet. The uncompressed path sends 10 messages truncated to 2,000 characters each -- that is at most 20,000 characters of context, well within any model's window. If token economy becomes a problem, add compression then.

**Recommendation**: Ship without `compressed`. The BorrowContextTool becomes dramatically simpler:

```ruby
def execute(conversation_id:)
  # ... validation ...
  # ... fetch messages ...
  # ... store on ChatAgent ...
  { success: true, message: "Context will be included in your next response." }
end
```

No `compress_context` prompt template. No synchronous LLM call inside a tool execution. No conditional branching. This also removes the `compress_context/system.prompt.erb` and `compress_context/user.prompt.erb` files from the spec.

---

## Improvements Needed

### 3. The borrowed context JSON structure is over-specified

The spec stores this in `borrowed_context_json`:

```ruby
{
  "source_conversation_id" => source_chat.obfuscated_id,
  "source_title" => source_chat.title_or_default,
  "messages" => formatted,
  "compressed" => compressed,
  "borrowed_at" => Time.current.iso8601
}
```

`compressed` and `borrowed_at` serve no purpose. Nothing reads them after storage. The `source_title` is only used in the success response to the agent, not when building the system prompt (the prompt uses `source_conversation_id` only). Strip it to what is actually consumed:

```ruby
{
  "source_conversation_id" => source_chat.obfuscated_id,
  "messages" => formatted
}
```

If you want the title in the system prompt (which would be reasonable), add it. But do not store metadata that nothing reads.

### 4. `cross_conversation_context_for` belongs on Agent, not Chat

The method `cross_conversation_context_for(agent)` lives on Chat but its primary concern is querying the agent's other conversations. Chat is the wrong home for this. The method's first action is to query `ChatAgent` records for a given agent, excluding the current chat. That is agent-centric logic.

Consider this instead:

```ruby
# In Agent
def other_conversation_summaries(excluding_chat:)
  chat_agents
    .joins(:chat)
    .where.not(chat_id: excluding_chat.id)
    .where.not(agent_summary: [nil, ""])
    .where("chats.updated_at > ?", 6.hours.ago)
    .where("chats.discarded_at IS NULL")
    .includes(:chat)
    .order("chats.updated_at DESC")
    .limit(10)
end
```

Then in `Chat#system_message_for`:

```ruby
if (summaries = agent.other_conversation_summaries(excluding_chat: self)).any?
  parts << format_cross_conversation_context(summaries)
end
```

This follows the existing pattern: `agent.memory_context` builds agent-centric context, and `system_message_for` assembles the parts. The formatting stays on Chat (it knows about prompt structure), but the query lives on Agent (it knows about its own conversations).

### 5. The message callback fans out too eagerly

The spec adds this to Message:

```ruby
after_create_commit :queue_agent_summaries, if: -> { role.in?(%w[user assistant]) && content.present? }

def queue_agent_summaries
  chat.agents.find_each do |agent|
    GenerateAgentSummaryJob.perform_later(chat, agent)
  end
end
```

Every single user or assistant message enqueues N jobs (one per agent in the chat). Yes, the job checks `summary_stale?` and exits early. But this still creates SolidQueue records for every message. In an active group chat with 4 agents, that is 4 jobs per message, most of which immediately exit.

**Recommendation**: Move the debounce check to the callback level to avoid even enqueuing:

```ruby
after_create_commit :queue_agent_summaries, if: -> { role.in?(%w[user assistant]) && content.present? }

def queue_agent_summaries
  chat.chat_agents.each do |chat_agent|
    next unless chat_agent.summary_stale?
    GenerateAgentSummaryJob.perform_later(chat, chat_agent.agent)
  end
end
```

This queries ChatAgent records (already loaded through the association) and avoids enqueuing jobs that will immediately no-op. The job should still check `summary_stale?` as a safety net (race conditions), but the callback should not blindly fan out.

### 6. The `consume_borrowed_context!` pattern has a subtle issue

```ruby
def consume_borrowed_context!
  return nil unless borrowed_context?
  context = borrowed_context_json
  update_columns(borrowed_context_json: nil)
  context
end
```

This is called from `Chat#borrowed_context_for`, which is called from `Chat#system_message_for`, which is called from `Chat#build_context_for_agent`. That method is called in `ManualAgentResponseJob#perform`. If the job fails after context is built but before the LLM call completes, the borrowed context is lost forever. The agent asked for context, it was consumed, but the response never happened.

This may be acceptable -- the spec's edge case table says "low cost" -- but it should be explicitly acknowledged as a design trade-off, not glossed over. Consider consuming in `on_end_message` instead, or at minimum documenting why consume-on-build is acceptable.

**Recommendation**: At minimum, add a note. Better: consume after the response succeeds, not during prompt building. The simplest approach is to mark it for consumption in the prompt builder but only clear it in a callback after the job completes successfully.

### 7. The prompt template structure is slightly off

The `generate_agent_summary` system prompt puts summary instructions first, then identity:

```erb
<%= summary_instructions %>

Your identity:
<%= identity %>
```

This is backwards. Identity should come first -- it frames everything else. The agent needs to know who it is before it knows what it is being asked to do. Every other prompt in the codebase (the system prompt itself, memory reflection) follows identity-first ordering.

```erb
Your identity:
<%= identity %>

<%= summary_instructions %>
```

And since we are removing `summary_prompt` (see point 1), `summary_instructions` becomes a static block in the template:

```erb
Your identity:
<%= identity %>

Summarize this conversation for your own reference. Focus on current state:
- What is being worked on right now?
- What decisions are pending?
- What has been agreed or resolved?

Do NOT narrate. Describe where things stand. Write exactly 2 lines.
```

Clean, simple, no configuration needed.

### 8. `borrowed_context_for` should not live on Chat

Similar to point 4, `borrowed_context_for(agent)` finds a ChatAgent, consumes its context, and formats it. The consumption logic is ChatAgent's responsibility. The formatting is prompt-building, which belongs with `system_message_for`. But the method mixes concerns.

Consider:

```ruby
# In Chat#system_message_for
if (borrowed = current_chat_agent&.consume_borrowed_context!)
  parts << format_borrowed_context(borrowed)
end
```

Where `format_borrowed_context` is a simple private method that only handles string formatting. The ChatAgent already knows about consuming. Chat already knows about prompt assembly. No need for a bridging method.

---

## What Works Well

**The core architecture is right.** Per-agent summaries on ChatAgent, background generation with debounce, system prompt injection, and a tool for on-demand full context -- this is a clean, layered design.

**The debounce-at-job-level pattern is pragmatic.** Checking `summary_stale?` inside the job is simple and correct. The spec correctly notes that the cost of a no-op job is negligible (though I recommend also checking at the callback level per point 5).

**The borrowed context as system-prompt-injection-for-one-activation is clever.** Putting it in the system prompt instead of the conversation history avoids permanent token inflation. This is the right trade-off for the use case.

**The BorrowContextTool follows existing tool patterns exactly.** Constructor signature, error handling, ChatAgent lookup -- all consistent with CloseConversationTool and SaveMemoryTool.

**The testing strategy is focused.** Unit tests for model methods, job tests for the background work, tool tests for the tool. No bloated integration test suites. The two end-to-end tests are appropriate.

**Edge case handling is thorough without being paranoid.** The table covers real scenarios without inventing unlikely ones. The "last writer wins" acceptance for race conditions is the right call.

---

## Summary of Recommended Changes

| Change | Impact |
|--------|--------|
| Remove `summary_prompt` from Agent entirely | -1 column, -1 validation, -1 method, -1 constant, -1 form field, -3 tests |
| Remove `compressed` mode from BorrowContextTool | -2 prompt templates, -1 param, -1 private method, -1 test |
| Strip `borrowed_context_json` to only what is consumed | Cleaner data |
| Move conversation summary query to Agent | Better separation of concerns |
| Check `summary_stale?` before enqueuing | Fewer no-op jobs |
| Fix prompt template ordering (identity first) | Consistency with codebase |
| Address consume-on-build risk for borrowed context | Reliability |
| Inline summary instructions into prompt template | Simpler prompt, no configuration |

The net result: fewer files, fewer columns, fewer tests, and a simpler feature that does the same thing. That is The Rails Way.
