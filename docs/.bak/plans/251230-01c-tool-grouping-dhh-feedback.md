# DHH-Style Review: Tool Grouping Plan - Revised with Scale Context

## A Necessary Mea Culpa

My previous reviews missed the forest for the trees. I was optimizing for Ruby beauty when the actual constraint is **agent capability at scale**. The owner is right: 50+ tools is not a hypothetical future - it is the near-term reality. With 15 tools arriving in days and more to follow, the "keep four beautiful simple tools" advice fails to address the real problem.

Let me reconsider with the correct constraints in mind.

---

## The Real Problem

The problem is not "how do we keep Ruby code beautiful." The problem is:

> How do we give agents access to 50+ capabilities without overwhelming them with 50+ tool definitions in their context?

This is a legitimate architectural challenge. LLMs have limited context windows and limited attention. A prompt with 50 tool definitions is genuinely different from one with 10. The cognitive load on the model matters. The token budget matters.

My previous critique that "your code should not contort itself to accommodate the limitations of an external system" was wrong in this context. The LLM is not an external system here - **it is the core of what you are building**. Optimizing for agent capability is optimizing for the product.

---

## Reassessing the Polymorphic Approach

With 50+ capabilities as the constraint, let me reconsider iteration 1a (the polymorphic approach):

### What I Got Wrong

1. **"Solving a problem that does not exist"** - The problem absolutely exists. Four tools is fine. Fifty tools is a real challenge for LLM attention and context.

2. **"PHP circa 2005"** - String-based dispatch inside a tool is not the same as string-based dispatch for application routing. Within a tool, it is more like a command pattern with subcommands. Git does this: `git remote add`, `git remote remove`. It is not beautiful Ruby, but it is a reasonable interface for a system that needs to present unified capabilities.

3. **"query_or_url is a code smell"** - Still true from a pure Ruby perspective, but the tradeoff might be acceptable if it halves the tool count for the LLM.

### What I Got Right

1. **Translation layers add complexity** - The `PROMPT_TYPES` mapping between LLM-facing names and model attributes is unnecessary. Use the same names everywhere.

2. **Error messages should be helpful** - Returning `allowed_actions` on validation errors is actually good for LLMs. They can self-correct.

3. **The existing tools are well-written** - They are. The question is whether well-written matters more than scalability.

---

## Recommendations for Scale

Given the 50+ tool constraint, here are patterns I would recommend:

### 1. Domain-Based Tool Consolidation

Group tools by domain, not by individual action. This is closer to iteration 1a's approach:

```
Individual tools (current):          Consolidated (for scale):
- view_system_prompt                 - agent_config (view/update prompts, name, settings)
- update_system_prompt               - web (search/fetch/extract)
- web_search                         - memory (save/recall/forget)
- web_fetch                          - file (read/write/list)
- save_memory                        - task (create/update/complete)
- recall_memory
...50 more
```

At 50+ capabilities, this could reduce tool count from 50 to perhaps 10-15 domain tools. That is a meaningful reduction for LLM context.

### 2. Make the Interface LLM-Native

If you are building for LLMs, design the interface for how LLMs think. They are good at:

- Following patterns (consistent parameter shapes)
- Self-correcting from structured errors
- Working with enums when the options are clear

The self-correcting error pattern from iteration 1a is actually good:

```ruby
{
  error: "Invalid action 'delete'",
  allowed_actions: ["view", "update"],
  allowed_prompt_types: ["system", "reflection", "memory", "name"]
}
```

This helps the LLM recover without another round-trip to read documentation.

### 3. Keep the Ruby Reasonable

Even accepting consolidation, we can avoid the worst excesses:

**Better: Subcommand pattern with clear methods**

```ruby
class AgentConfigTool < RubyLLM::Tool
  description "Manage agent configuration. Actions: view, update"

  param :action, type: :string, desc: "view or update", required: true
  param :field, type: :string, desc: "system_prompt, reflection_prompt, memory_reflection_prompt, or name", required: true
  param :value, type: :string, desc: "New value (required for update)", required: false

  def execute(action:, field:, value: nil)
    return validation_error unless valid_action?(action) && valid_field?(field)

    send("#{action}_field", field, value)
  end

  private

  def view_field(field, _)
    { field: field, value: @agent.public_send(field) }
  end

  def update_field(field, value)
    return { error: "value required for update" } if value.blank?
    @agent.update!(field => value)
    { field: field, value: value, success: true }
  end
end
```

This is still string dispatch, but the methods are focused. Each action is a clear, testable unit.

**Avoid: The 200-line mega-tool**

The risk with consolidation is creating God tools that do everything badly. If a consolidated tool exceeds 100 lines, it is probably doing too much. Extract concerns.

### 4. Consider a Tool Registry Pattern

For true scale (50+ capabilities), consider a registry that dynamically builds tool definitions:

```ruby
class ToolRegistry
  def tools_for_context(context)
    available_tools.select { |t| t.available_in?(context) }
                   .group_by(&:domain)
                   .map { |domain, tools| ConsolidatedTool.new(domain, tools) }
  end
end
```

This lets you write individual capability classes but present them to the LLM as consolidated domain tools. Best of both worlds: clean Ruby internally, minimal tool count externally.

---

## Revised Assessment of Iteration 1c

The current iteration (1c) takes the conservative approach: extend existing tools, keep web tools separate, end up with 4 tools instead of 2.

**For the current scope**: This is fine. It works. The code is clean.

**For 50+ capabilities**: This approach does not scale. Each new capability adds a tool. You will hit the original problem.

---

## My Recommendation

**Short term**: Implement iteration 1c as written. It is correct for the immediate requirement (support new prompt types). The code is clean and the migration is minimal.

**Medium term**: Plan for domain-based consolidation. As you add the next 15 tools, group them:

- **Agent tools**: prompt management, settings, configuration
- **Memory tools**: save, recall, search, forget
- **Web tools**: search, fetch, (later: extract, crawl)
- **Task tools**: create, update, complete, list
- **File tools**: read, write, list, search

Each domain becomes one tool with an action parameter. The string dispatch is the cost of scale.

**Long term**: Consider the registry pattern that presents clean tool definitions to LLMs while keeping internal implementation modular.

---

## On Ruby Purity vs Product Goals

Rails doctrine says "conceptual compression is about making the complex simple." But compression has costs. The polymorphic tool pattern adds complexity to Ruby code to reduce complexity for LLMs.

That tradeoff is valid when:
1. LLM capability is the core product value
2. Tool count genuinely impacts LLM performance
3. The Ruby complexity remains manageable (not God classes)

Your context hits all three. The agents liberating themselves requires they have access to many capabilities. The tool count does matter for their context windows. And the proposed consolidation, done carefully, keeps tools under 100 lines each.

I was wrong to dismiss the polymorphic approach outright. It is not beautiful Ruby. But it might be the right architecture for an LLM-native application at scale.

---

## Final Verdict

**Iteration 1c: Approved for immediate implementation.** It solves the current requirement cleanly.

**Iteration 1a (polymorphic approach): Conditionally approved for future consolidation.** When you hit 15+ tools and can measure LLM degradation, the consolidation approach becomes justified. Apply these refinements:

1. Use actual attribute names, no translation layers
2. Keep consolidated tools under 100 lines
3. Include self-correcting error responses
4. Test each action/subcommand independently
5. Consider the registry pattern for true scale

The goal is not beautiful Ruby. The goal is capable agents. Sometimes those align. Sometimes they trade off. Know which game you are playing.

---

*"Optimizing for the wrong constraint is the root of all evil in software architecture."* - Revised wisdom
