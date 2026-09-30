# DHH-Style Review: Tool Grouping Plan - Iteration D

## Overall Assessment

This iteration delivers what I asked for. It embraces domain consolidation without apology, keeps both tools under 100 lines, uses direct attribute names everywhere, and includes self-correcting errors. The separate `query` + `url` approach for WebTool is unambiguously better than `query_or_url`. This is ready for implementation.

The Ruby is not as beautiful as four single-purpose tools. But that was never the goal. The goal is scalable agent capability, and this achieves it.

---

## What Works Well

### 1. Direct Field Names

The spec correctly eliminates the translation layer I criticized. `system_prompt` in the API means `system_prompt` on the model. No `PROMPT_TYPES` mapping. No `conversation_consolidation` indirection. One name, everywhere. This is Rails orthodoxy: convention over configuration means naming things once and using that name consistently.

### 2. Separate `query` + `url` Parameters

This is cleaner than `query_or_url`. The previous iteration acknowledged `query_or_url` was a code smell but accepted it for pragmatic reasons. This iteration shows the pragmatism was unnecessary:

```ruby
param :query, desc: "Search query (required for search action)"
param :url,   desc: "URL to fetch (required for fetch action)"
```

The tool validates which parameter is required for which action. The error messages guide the LLM to the right parameter. This is how the interface should have looked from the start.

### 3. Self-Correcting Error Pattern

The error responses are LLM-native in the best sense:

```ruby
{
  type: "error",
  error: "query is required for search action",
  action: "search",
  required_param: "query",
  allowed_actions: ["search", "fetch"]
}
```

Everything the LLM needs to self-correct is in the response. No round-trip for documentation. No guessing. This is thoughtful interface design.

### 4. Line Count Discipline

AgentConfigTool: 68 lines. WebTool: 98 lines. Both under the 100-line guideline. Both with clearly separated private methods. This is consolidation without God classes.

The future domain tool sketches (MemoryTool, TaskTool) show the pattern scales without explosion.

### 5. Comprehensive Test Coverage

The test plan covers all the cases that matter:

- Every action on every field
- Self-correcting error content
- Context restrictions
- Model validation passthrough
- Rate limiting
- Network edge cases

Tests are the specification. These tests specify the behavior clearly.

---

## Minor Improvements

### 1. Consider `freeze` on FIELDS

The spec freezes `ACTIONS` but not `FIELDS`:

```ruby
ACTIONS = %w[view update].freeze
FIELDS = %w[name system_prompt reflection_prompt memory_reflection_prompt].freeze  # Add .freeze
```

Minor consistency issue. Both constants are immutable; both should say so.

### 2. The `(not set)` String

```ruby
value: @current_agent.public_send(field) || "(not set)"
```

This works, but consider whether `nil` would be clearer for the LLM. The string "(not set)" is human-readable but adds a special case the LLM must interpret. A null value is unambiguous. Either approach is defensible; just be intentional about the choice.

### 3. The `_action` Suffix Pattern

The spec shows `view_field` and `update_field` rather than the `view_action` pattern from the overview:

```ruby
# Overview pattern:
def action_one_action(**params)

# Actual implementation:
def view_field(field, value)
def update_field(field, value)
```

The actual implementation (`view_field`, `update_field`) reads better than `view_field_action` would. Keep the implementation; the overview can be updated to show that `_{action}` is sufficient without doubling up words.

---

## The Pattern Scales

The section on future domain tools demonstrates the architecture holds:

```ruby
class MemoryTool < RubyLLM::Tool
  ACTIONS = %w[save recall search forget].freeze
  # ...
end

class TaskTool < RubyLLM::Tool
  ACTIONS = %w[create update complete list].freeze
  # ...
end
```

At 50 capabilities, this yields approximately 10 domain tools instead of 50 individual tools. The math works. The pattern is established. Future capabilities slot in cleanly.

---

## One Architectural Question

The spec mentions `@search_count` as instance state for rate limiting:

```ruby
def initialize(chat: nil, current_agent: nil)
  # ...
  @search_count = 0
end
```

This implies a new tool instance per response generation. Verify this is indeed the lifecycle. If tool instances are reused across multiple agent turns, the rate limit would incorrectly persist. The comment says "per session" which I interpret as "per response generation" - just confirm the lifecycle matches the intent.

---

## Final Verdict

**Approved for implementation.**

This iteration correctly implements the scale-oriented patterns from my revised feedback:

1. Domain-based consolidation with `action` as first parameter - Yes
2. Direct attribute names without translation layers - Yes
3. Self-correcting errors with valid options - Yes
4. Under 100 lines per tool - Yes (68 and 98)
5. Focused private methods - Yes
6. Separate parameters instead of `query_or_url` - Better than required

The migration path is clear. The rollback plan is documented. The tests are comprehensive. The documentation will help future contributors extend the pattern.

Build it.

---

*"Perfectionism in architecture is knowing when good enough serves the actual goal better than theoretical ideal serves no one."*
