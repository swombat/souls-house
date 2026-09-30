# Multi-Threaded Thinking Revision B: DHH-Style Review

## Overall Assessment

This is a dramatically improved spec. The major cuts from Revision A -- killing `summary_prompt`, killing `compressed` mode, leaning out the JSON structure -- were exactly right. The consume-after-success pattern is a meaningful reliability improvement. What remains is clean, focused, and follows the existing codebase patterns well. This is close to shippable. The feedback below is refinement, not restructuring.

---

## Remaining Over-Engineering

### 1. The `format_cross_conversation_context` method is doing too much string assembly

The method on Chat builds a multi-line string with a header, an explanation paragraph, bullet points, and a usage hint. That is prompt copywriting, not code logic. It works, but the string construction is noisy.

The existing pattern in the codebase (`whiteboard_index_context`, `active_whiteboard_context`, `conversation_topic_context`) does exactly the same thing -- builds formatted strings inline in private methods. So this is consistent. No change needed, just noting that the pattern is getting heavy. If you add one more context section after this, consider whether a lightweight template approach would be cleaner than more string concatenation methods on Chat.

Not a blocker. Ship it as-is.

### 2. The testing strategy is well-scoped but has one redundancy

The `other_conversation_summaries` tests list six cases:

- returns summaries from other conversations
- excludes the specified chat
- excludes conversations older than 6 hours
- excludes discarded conversations
- excludes blank summaries
- limits to 10 results

The first two are the same test. "Returns summaries from other conversations" necessarily demonstrates that it excludes the current one. Collapse them into one test that asserts both the positive (got the right ones) and the negative (did not get the excluded one). Five tests, not six, and clearer intent.

---

## The Consume-After-Success Pattern

This is the right fix. The first iteration had a real bug: consume during prompt assembly meant an LLM failure after context-building but before response-completion would destroy the borrowed context permanently. Moving the clear to `on_end_message` solves this cleanly.

One question worth addressing in the spec: **what happens if `on_end_message` fires but the job still raises after that callback?** Looking at the actual `ManualAgentResponseJob`, the flow is:

```
on_end_message fires -> finalize_message! -> ...
llm.complete returns -> elapsed time logged -> rescue block
```

If `finalize_message!` raises inside `on_end_message`, the borrowed context would already be cleared by `clear_borrowed_context!` if it is placed after `finalize_message!`. But if `clear_borrowed_context!` is placed before `finalize_message!`, it could be cleared before the message is persisted.

**Recommendation**: In the spec's code examples, `clear_borrowed_context!` is placed after `finalize_message!` and after `notify_subscribers!`. That ordering is correct. Make the ordering explicit in the spec text: "Clear borrowed context as the last action in `on_end_message`, after all other work has succeeded." One sentence, prevents a subtle implementation mistake.

---

## The Debounce-at-Callback Pattern

This is a good optimization over Revision A. Checking `summary_stale?` before enqueuing avoids pointless SolidQueue records. The belt-and-suspenders approach (check in callback, re-check in job) is pragmatic.

One minor concern: the callback loads `chat.chat_agents` eagerly. In a group chat with 4 agents, this is a single query returning 4 rows -- negligible. But the spec should note that `chat_agents` is the association (already loaded or a cheap query), not `chat.agents.find_each` which would hit the agents table. The spec already uses `chat.chat_agents.each` -- good.

No changes needed. This is the right pattern.

---

## Method Placement

### `Agent#other_conversation_summaries(exclude_chat_id:)` -- correct

This follows `Agent#memory_context` exactly. The agent queries its own cross-conversation data. Chat formats it for the prompt. Clean separation.

### `Chat#format_cross_conversation_context` and `Chat#format_borrowed_context` -- correct

Chat owns prompt assembly. These are formatting methods that turn data into prompt sections. They belong alongside `whiteboard_index_context` and `conversation_topic_context`. Consistent.

### `ChatAgent#clear_borrowed_context!` -- correct

The ChatAgent owns the column. The method is a thin wrapper around `update_columns`. It belongs here.

### `Message#queue_agent_summaries` -- worth a thought

The callback on Message triggers summary generation. This is the right trigger point (messages are the event), but it means Message now knows about ChatAgent and GenerateAgentSummaryJob. Message already knows about Chat, and Chat knows about ChatAgent, so this is one hop of coupling. Acceptable, but if you find yourself adding more callbacks on Message that fan out to ChatAgents, consider moving the fan-out into a Chat method that Message calls.

For now, this is fine.

---

## Code Clarity

### The `find_source_chat` method in BorrowContextTool is clean

```ruby
def find_source_chat(conversation_id)
  decoded_id = Chat.decode_id(conversation_id)
  return nil unless decoded_id

  ChatAgent.find_by(
    agent_id: @current_agent.id,
    chat_id: decoded_id
  )&.chat
end
```

This is three lines that do decode, authorize, and return. Expressive. The safe navigation operator is appropriate here.

### The `error` one-liner is idiomatic

```ruby
def error(msg) = { error: msg }
```

Consistent with `CloseConversationTool`. Good.

### The prompt template reads well

Identity first, then task instructions, then conditional previous summary. The ordering is correct, the instructions are concrete ("Write exactly 2 lines"), and the "Respond with the summary text only" closing is a good guardrail.

---

## Specific Nitpicks

### 1. `exclude_chat_id:` should be `exclude_chat_id` not `excluding_chat:`

The spec uses `exclude_chat_id:` which takes an integer ID. This is the right call -- passing an ID is simpler than passing the whole Chat object. But be consistent: the method is called from `format_cross_conversation_context(agent)` which already has `self.id` available. Clean.

### 2. The `where("chats.discarded_at IS NULL")` should use the discard gem's scope if available

If the codebase uses `discard` (the `discarded_at` column suggests it does), there may be a `kept` or `undiscarded` scope available on Chat. Using `merge(Chat.kept)` would be more idiomatic than raw SQL. Check the Chat model.

### 3. The rescue in GenerateAgentSummaryJob swallows all errors

```ruby
rescue StandardError => e
  Rails.logger.error "..."
end
```

This means a persistent bug (say, a nil pointer in the transcript building) will silently fail forever. Consider whether `rescue StandardError` should be narrowed to the LLM-specific errors you actually expect (`RubyLLM::Error`, network errors). A genuine bug in the summary generation code should raise and be visible in error tracking.

If you want belt-and-suspenders: log AND re-raise for non-LLM errors, swallow only LLM/network errors.

---

## Summary of Recommended Changes

| Change | Type |
|--------|------|
| Make `clear_borrowed_context!` ordering in `on_end_message` explicit (after finalize) | Clarification |
| Collapse first two `other_conversation_summaries` tests into one | Minor cleanup |
| Use discard gem scope instead of raw SQL for `discarded_at IS NULL` | Idiom |
| Narrow rescue in GenerateAgentSummaryJob to expected error types | Reliability |

Four small changes. The spec is ready for implementation.
