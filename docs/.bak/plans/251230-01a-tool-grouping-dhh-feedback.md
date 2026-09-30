# DHH-Style Review: Tool Grouping Implementation Plan

## Overall Assessment

This spec commits one of the cardinal sins of software design: **solving a problem that does not exist**. The stated goal of "reducing tool count and context bloat" is solving for LLM token limits by adding complexity to your codebase. That is backwards. Your code should not contort itself to accommodate the limitations of an external system.

The existing tools are **beautiful** in their simplicity. `ViewSystemPromptTool` is 21 lines. `UpdateSystemPromptTool` is 38 lines. `WebFetchTool` is 61 lines. `WebSearchTool` is 86 lines. Each does one thing. Each is immediately comprehensible. The proposed "polymorphic" pattern replaces these with larger, more complex tools that require mental gymnastics to understand.

This spec would not be accepted into Rails core.

---

## Critical Issues

### 1. Premature Abstraction Driven by External Constraints

The entire motivation is "reducing tool count for LLM context." This is letting an external system's limitations drive your architecture. If your LLM is struggling with four simple tools, the problem is not the tools - the problem is how you are presenting them.

Rails does not compromise its architecture because some database has quirks. It provides clean abstractions and lets adapters handle the differences.

### 2. "Polymorphic Tool Pattern" Is Not a Pattern - It Is Complexity

The spec introduces what it calls a "polymorphic tool pattern" as if naming complexity makes it good. What you have actually done is taken single-responsibility classes and merged them into multi-responsibility classes hidden behind string-based dispatch.

Compare:

```ruby
# Current: Crystal clear
ViewSystemPromptTool.new.execute
UpdateSystemPromptTool.new.execute(system_prompt: "new")

# Proposed: What does this do? You have to read the switch statement.
PromptManagerTool.new.execute(action: "view", prompt_type: "system")
```

The second form hides the operation behind strings. You have reinvented dynamic dispatch badly.

### 3. The `query_or_url` Parameter Is a Code Smell

When you name a parameter `query_or_url`, you are admitting that your abstraction is wrong. A parameter should be one thing. This parameter's meaning changes based on another parameter. That is a symptom of forcing two different operations into one interface.

From the spec:
```ruby
param :query_or_url, type: :string,
      desc: "Search query for 'search' action, or URL for 'fetch' action"
```

This is indefensible. The description literally has to explain what the parameter means in different contexts.

### 4. String-Based Action Dispatch Is Anti-Ruby

Ruby gives you objects, methods, and polymorphism. The proposed pattern throws these away in favor of:

```ruby
case action
when "view" then view_prompt(prompt_type)
when "update" then update_prompt(prompt_type, content)
end
```

This is PHP circa 2005. Ruby solved this problem decades ago with objects.

### 5. Unnecessary Indirection Through PROMPT_TYPES Mapping

```ruby
PROMPT_TYPES = {
  "system" => :system_prompt,
  "conversation_consolidation" => :reflection_prompt,
  "memory_management" => :memory_reflection_prompt,
  "name" => :name
}.freeze
```

You have introduced a translation layer between what the LLM calls things and what your model calls things. Now you have two naming systems to maintain. When you add a new prompt type, you update the model AND this mapping. Why? For what benefit?

If the LLM should call it `system`, name the attribute `system`. If the model calls it `system_prompt`, have the tool accept `system_prompt`. Do not create a rosetta stone.

### 6. "Self-Correcting Errors" Is Overengineering

Returning `allowed_actions` and `allowed_prompt_types` on every error is clever. Too clever. The tool definition already specifies valid values. You are duplicating that information in error responses.

If an LLM cannot follow clear parameter descriptions, adding more data to error responses will not help.

---

## Improvements Needed

### Keep the Existing Tools

The existing implementation is superior:

**ViewSystemPromptTool** (21 lines) - Does one thing, does it simply:
```ruby
def execute
  return { error: "This tool only works in group conversations" } unless @chat&.group_chat?
  return { error: "No current agent context" } unless @current_agent

  {
    name: @current_agent.name,
    system_prompt: @current_agent.system_prompt || "(no system prompt set)"
  }
end
```

This is the code that belongs in Rails documentation. It is exemplary.

**UpdateSystemPromptTool** (38 lines) - Clear, focused, handles edge cases cleanly.

### If You Must Reduce Tool Count, Group at the Schema Level

If LLM token limits are genuinely causing problems (measure this first), the solution is not to make your tools more complex. The solution is to group tool descriptions more efficiently in your prompt generation.

Consider:

```ruby
# Keep your simple tools
# But present them to the LLM as grouped:
#
# Prompt Tools:
# - view_system_prompt: View your system prompt
# - update_system_prompt: Update your system prompt or name
#
# Web Tools:
# - web_search: Search the web
# - web_fetch: Fetch a page
```

Same architecture. Better presentation. No added complexity.

### If You Must Extend ViewSystemPromptTool

If viewing other prompt types is genuinely needed, extend the existing tool minimally:

```ruby
class ViewSystemPromptTool < RubyLLM::Tool
  VIEWABLE = {
    system_prompt: "system_prompt",
    reflection: "reflection_prompt",
    memory: "memory_reflection_prompt",
    name: "name"
  }.freeze

  description "View one of your prompts: system_prompt (default), reflection, memory, or name"

  param :which, type: :string, required: false, default: "system_prompt"

  def execute(which: "system_prompt")
    # ... simple implementation
  end
end
```

This keeps the tool focused (viewing) while allowing selection. It does not mix viewing and updating.

---

## What Works Well

### The Existing Tools Are Excellent

Look at `SaveMemoryTool`:

```ruby
def error(msg) = { error: msg }
```

One-line method definition. Beautifully idiomatic Ruby 3. The existing tools demonstrate exactly the kind of code that should be preserved, not replaced.

### The Test Structure in the Spec Is Solid

The proposed tests are well-organized and cover the right cases. The testing approach is sound - only the thing being tested is wrong.

### The Data Migration Plan Is Thoughtful

The rake task for migrating tool names is cleanly written. It is a pity it should not be needed.

---

## Refactored Approach

Do not do this refactoring. The existing code is better.

If token limits are genuinely a problem:

1. **Measure first**: How many tokens do the current tool descriptions consume? Is this actually causing issues?

2. **Compress descriptions, not code**: Write terser tool descriptions without changing the tool architecture.

3. **Consider tool grouping at the prompt level**: Present related tools together in the LLM context without merging their implementations.

4. **Accept some token cost for clarity**: Clear, focused tools may be worth a few extra tokens if they lead to more accurate tool usage.

If you absolutely must reduce tool count (and I am not convinced you must), the only acceptable consolidation would be:

- Keep `WebSearchTool` and `WebFetchTool` separate - they do fundamentally different things
- Keep `ViewSystemPromptTool` and `UpdateSystemPromptTool` separate - read vs write is a fundamental distinction
- Extend `ViewSystemPromptTool` with an optional `which` parameter if viewing other prompts is needed
- Extend `UpdateSystemPromptTool` with optional parameters for other prompt types if updating them is needed

The tools remain single-purpose (viewing, updating) but gain flexibility in what they view or update.

---

## Summary

This spec is a solution looking for a problem. It takes four simple, clear, Rails-worthy tools and proposes replacing them with two complex, multi-purpose tools that require string-based dispatch, parameter overloading, and translation layers.

The "polymorphic tool pattern" should be called what it is: a complexity pattern. It makes code harder to understand, harder to maintain, and harder to extend in the future.

Keep your beautiful simple tools. They are a joy to read. Do not sacrifice them on the altar of token efficiency.

---

*"Conceptual compression is about making the complex simple, not making the simple complicated."* - The Rails Doctrine
