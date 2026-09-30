# DHH Review: Memory Management v2

## Overall Assessment

This is a **dramatically improved** spec. Every critical issue from the first review has been addressed: soft-delete is gone, `content_hash` is gone, `token_estimate` is a computed method, `core_token_budget` is a constant, the job iterates simply, and scopes remain untouched. The tool delegates audit and serialization to the model. The migration is two columns. This is close to Rails-worthy. What remains is trimming -- a few places where the code does slightly more than it needs to, and one structural question about the tool's line count.

## Critical Issues

None. The first review's critical issues are all resolved.

## Improvements Needed

### 1. `non_constitutional` scope is unused

```ruby
scope :non_constitutional, -> { where(constitutional: false) }
```

Nothing in the spec calls this scope. The tool filters constitutional memories inline with `.select(&:constitutional?)` after loading. Either use the scope in the tool (better) or drop it. Dead code should not ship.

If you keep it, use it in `consolidate_action` and `delete_action` to avoid loading constitutional memories in the first place:

```ruby
memories = @agent.memories.core.non_constitutional.where(id: memory_ids)
# Now no need to check constitutional? -- they're already excluded
```

But then you lose the ability to return a specific error naming which IDs were constitutional. Pick one: helpful error messages or clean scoping. I would pick the helpful errors for an agentic tool -- the LLM needs to understand why its action failed. So drop the `non_constitutional` scope.

### 2. `search_action` uses raw ILIKE with unsanitized input

```ruby
.where("content ILIKE ?", "%#{query}%")
```

The `query` comes from an LLM tool call, not user input, so SQL injection risk is low -- ActiveRecord parameterizes it. But the `%` wrapping means a query containing `%` or `_` will behave as wildcards. Use `sanitize_sql_like`:

```ruby
.where("content ILIKE ?", "%#{AgentMemory.sanitize_sql_like(query)}%")
```

One line change. Do it right.

### 3. The `expired?` method is orphaned

```ruby
def expired?
  journal? && created_at < JOURNAL_WINDOW.ago
end
```

Nothing in this spec calls `expired?`. If it exists for the existing `MemoryReflectionJob`, it belongs in the existing codebase already. If it is new, what is it for? Do not add methods that have no caller. If it is existing code shown for context, mark it as such -- the spec implies it is new by including it in the model additions.

### 4. `param_error` includes `allowed_actions` but `validation_error` also includes it

Both error helpers return `allowed_actions: ACTIONS`. This is a nice touch for LLM tool use -- it tells the model what it can do. But `param_error` does not need `allowed_actions` because the action was valid, only the params were wrong. Returning allowed actions on a param error is noise:

```ruby
def param_error(action, param)
  { type: "error", error: "#{param} is required for #{action}" }
end
```

Keep `allowed_actions` only on `validation_error` where the action itself was invalid.

### 5. `delete_action` accepts both `id` and `ids` -- consolidate interface

The `delete_action` accepts either `id:` or `ids:`, doing branching logic to normalize them. But `consolidate_action` only accepts `ids:`. This asymmetry means the LLM has two different interfaces for bulk operations. Pick one pattern. Since delete of a single memory is the common case:

- `delete_action` takes `id:` (singular)
- `consolidate_action` takes `ids:` (plural, because consolidation is inherently multi-record)

This is already what the params declare. Remove `ids` support from `delete_action`:

```ruby
def delete_action(id: nil, **)
  return param_error("delete", "id") if id.blank?

  memory = @agent.memories.core.find_by(id: id)
  return { type: "error", error: "Memory ##{id} not found" } unless memory
  return { type: "error", error: "Cannot delete constitutional memory ##{id}" } if memory.constitutional?

  memory.audit_refinement("delete", memory.content, nil)
  memory.destroy!
  @stats[:deleted] += 1

  { type: "deleted", id: memory.id }
end
```

If the LLM wants to delete multiple memories, it calls delete multiple times. That is fine -- each call is individually audited, which is actually better for the audit trail.

### 6. Tool line count

With the `non_constitutional` scope removed, `param_error` simplified, and `delete_action` trimmed, the tool should land comfortably under 100 lines. Verify this after applying the changes. The current spec version looks like it is right at the boundary -- probably 95-100 lines for the tool class itself, which is acceptable.

### 7. `consolidate_action` should guard against single-ID consolidation

If the LLM passes a single ID to consolidate, it is just an update with extra steps (and a destroy). Add a guard:

```ruby
return { type: "error", error: "consolidate requires at least 2 memory IDs" } if memory_ids.size < 2
```

This prevents the agent from accidentally destroying a memory by "consolidating" it with itself.

### 8. Minor: `earliest = memories.minimum(:created_at)` fires a separate query

You already have `memories` loaded. Use Ruby:

```ruby
earliest = memories.map(&:created_at).min
```

One fewer database round trip.

## What Works Well

- **Every critical issue from v1 is resolved.** Soft-delete gone, content_hash gone, token_estimate computed, budget is a constant, scopes untouched. This shows disciplined iteration.
- **Two-column migration.** Minimal footprint. No indexes. No backfill. Perfect.
- **`audit_refinement` and `as_ledger_entry` on the model.** Data formatting lives where the data lives. The tool stays focused on orchestrating actions.
- **`before_destroy :prevent_constitutional_destruction`** is the Rails Way -- a model-level invariant, not a check scattered across callers.
- **Authorization is correct.** `current_account.agents.find(params[:agent_id]).memories.find(params[:id])` -- scoped through account. Good.
- **The job is simple.** `find_each`, `needs_refinement?`, `refine_agent`. No complex queries. No premature optimization. This is how a weekly batch job should read.
- **The prompt is well-crafted.** Clear rules, structured ledger, explicit instructions to call `complete`. The LLM will know what to do.
- **`retry_on` for rate limits and server errors.** Proper job resilience.
- **Edge cases section is thorough.** The "LLM never calls complete" case is correctly handled by RubyLLM's tool-use cycle limit.

## Summary

This spec is ready to build with minor adjustments. The architecture is clean, the code is idiomatic, and the complexity is proportional to the problem. The remaining feedback is polish, not structural. Apply the tweaks above and ship it.
