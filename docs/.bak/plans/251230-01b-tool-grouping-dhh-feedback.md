# DHH-Style Review: Tool Grouping Implementation Plan (Revised)

## Overall Assessment

This revision is **vastly improved** and demonstrates that the author actually listened. The original spec committed heresy against simplicity. This one repents.

The key insight was correct: the existing tools are not the problem. They are small, focused, and immediately comprehensible. The first iteration tried to solve token bloat by adding code complexity. This iteration solves the actual requirement (support new prompt types) by minimally extending existing patterns.

This spec is now **acceptable for implementation** with minor refinements.

---

## Did It Address My Concerns?

### 1. `query_or_url` Code Smell - ADDRESSED

The web tools remain untouched. Search and fetch stay separate. Good. They do fundamentally different things and deserve different tools. The author correctly identified that merging them would require parameter overloading that violates basic principles of good API design.

### 2. String-Based Action Dispatch - ADDRESSED

Gone. There is no `case action` statement. The tool itself is the action. `ViewPromptTool` views. `UpdatePromptTool` updates. This is how Ruby works.

### 3. Keep Existing Beautiful Tools - ADDRESSED

The spec explicitly states: "Keep the existing beautiful, focused tools" and "Extend them, not replace them." The author understood.

### 4. Parameter Names Matching Attributes - ADDRESSED

The original spec had a `PROMPT_TYPES` mapping that translated between LLM-facing names (`conversation_consolidation`) and model attributes (`reflection_prompt`). This translation layer was unnecessary complexity.

The new spec uses attribute names directly:

```ruby
param :system_prompt, type: :string
param :reflection_prompt, type: :string
param :memory_reflection_prompt, type: :string
param :name, type: :string
```

No translation. The LLM calls it what the model calls it. Clean.

---

## What Works Well

### The ViewPromptTool Design

```ruby
def execute(which: "system_prompt")
  return error("This tool only works in group conversations") unless @chat&.group_chat?
  return error("No current agent context") unless @current_agent
  return error("Unknown prompt type: #{which}. Valid types: #{PROMPTS.keys.join(', ')}") unless PROMPTS.key?(which)

  attribute = PROMPTS[which]
  value = @current_agent.send(attribute)

  {
    name: @current_agent.name,
    which: which,
    value: value.presence || "(not set)"
  }
end
```

This is a sensible extension of `ViewSystemPromptTool`. It stays focused on viewing. The optional `which` parameter defaults to `system_prompt`, preserving backward compatibility. The error messages are helpful without being over-engineered.

### The UpdatePromptTool Design

```ruby
def execute(system_prompt: nil, reflection_prompt: nil, memory_reflection_prompt: nil, name: nil)
  # ...
  updates = {
    system_prompt: system_prompt,
    reflection_prompt: reflection_prompt,
    memory_reflection_prompt: memory_reflection_prompt,
    name: name
  }.compact

  return error("Provide at least one field to update") if updates.empty?

  if @current_agent.update(updates)
    # ...
  end
end
```

This follows the exact pattern of the existing `UpdateSystemPromptTool`. Multiple optional parameters, `compact` to filter provided values, direct pass-through to `update`. Any Rails developer recognizes this immediately. The new fields slot in naturally.

### The Migration

The migration is straightforward and reversible. It touches only the data that needs changing. No complexity, no cleverness.

### The Comparison Table

The spec includes a comparison table showing the improvements. This demonstrates self-awareness. The author knows why the old approach was wrong:

| Aspect | First Iteration | This Revision |
|--------|-----------------|---------------|
| String dispatch | Yes (`case action`) | No |
| Parameter overloading | Yes (`query_or_url`) | No |
| Translation layers | Yes (`PROMPT_TYPES`) | No |
| Lines per tool | ~200 | ~35-45 |

That last line is telling. The first iteration was **five times longer** to do the same thing. Complexity is not a feature.

---

## Remaining Issues

### 1. The `PROMPTS` Hash in ViewPromptTool Is Unnecessary

Look at this:

```ruby
PROMPTS = {
  "system_prompt" => :system_prompt,
  "reflection_prompt" => :reflection_prompt,
  "memory_reflection_prompt" => :memory_reflection_prompt,
  "name" => :name
}.freeze
```

The keys and values are identical except for symbol vs string. This mapping exists only to validate the input and convert string to symbol. But you do not need it.

Simpler:

```ruby
VIEWABLE_ATTRIBUTES = %w[system_prompt reflection_prompt memory_reflection_prompt name].freeze

def execute(which: "system_prompt")
  return error("...") unless VIEWABLE_ATTRIBUTES.include?(which)

  value = @current_agent.public_send(which)
  # ...
end
```

Or even simpler, trust Active Model:

```ruby
def execute(which: "system_prompt")
  return error("...") unless @current_agent.respond_to?(which) && safe_attribute?(which)
  # ...
end
```

The current implementation works, but the hash mapping strings to identical symbols is a minor code smell.

### 2. Consider Keeping the Original Tool Names

The spec renames `ViewSystemPromptTool` to `ViewPromptTool` and `UpdateSystemPromptTool` to `UpdatePromptTool`. This requires a migration to update all agent configurations.

Alternative: keep the original names and just extend them. `ViewSystemPromptTool` that can also view other prompts is slightly awkward naming, but it eliminates the migration entirely. The naming awkwardness is minor; migrations are operational risk.

However, if you are committed to the rename (and the cleaner naming is appealing), the migration as written is acceptable.

### 3. Minor: Error Message Consistency

The existing `UpdateSystemPromptTool` uses `blank?` for validation:

```ruby
return { error: "..." } if system_prompt.blank? && name.blank?
```

The new spec uses `empty?`:

```ruby
return error("Provide at least one field to update") if updates.empty?
```

This is actually correct - you are checking if the hash is empty after `compact`. But ensure the behavior matches: `blank?` considers empty strings as blank, while the new approach with `compact` only removes `nil` values. If someone passes `system_prompt: ""`, the old tool would reject it, the new tool would accept it and update with an empty string.

Decide which behavior you want and be consistent.

### 4. The Tests Are Good But Verbose

The test structure is solid and comprehensive. The tests in the spec cover all the cases they should. One minor suggestion: the test file could use some shared setup extraction. Multiple tests create tools with the same configuration. But this is a style preference, not a requirement.

---

## Final Verdict

**Approved for implementation** with optional refinements.

This revision demonstrates the right approach:

1. Identify what actually needs to change (support for new prompt types)
2. Extend existing patterns rather than replacing them
3. Keep tools focused on single responsibilities
4. Avoid clever abstractions that add complexity without adding value
5. Use Ruby's strengths (keyword arguments, optional parameters, `compact`) rather than fighting them

The resulting tools will be 35-45 lines each, focused, and immediately comprehensible to any Rails developer. This is the standard.

The web tools remain untouched because they were already correct. The prompt tools gain new capabilities through minimal extension of proven patterns. The migrations are clean and reversible.

This is how evolution should work. Not revolution for the sake of abstraction, but thoughtful extension that respects what came before.

Implement it.

---

*"The best code is the code you never have to explain."* - The Rails Doctrine

