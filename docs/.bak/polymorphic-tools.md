# Polymorphic Tools Pattern

## Overview

As Helix Kit scales to 50+ agent capabilities, we face a critical constraint: LLM context limits. Traditional one-tool-per-action approaches would create 50+ tools, causing significant context bloat and degrading agent performance.

**Domain-based tool consolidation** solves this by grouping related capabilities into single tools:

| Approach | Tools at 50 capabilities | Context Impact |
|----------|--------------------------|----------------|
| One tool per action | 50+ tools | Significant bloat |
| Domain consolidation | 10-15 tools | Manageable |

Each domain tool accepts an `action` parameter plus domain-specific parameters, routing internally to focused private methods. This pattern keeps tools under 100 lines while supporting multiple related capabilities.

## The Pattern

### Core Structure

Domain tools follow a consistent pattern:

```ruby
class DomainTool < RubyLLM::Tool
  # Define supported actions
  ACTIONS = %w[action_one action_two].freeze

  # Optional: domain-specific constants
  FIELDS = %w[field_one field_two].freeze

  description "Brief description. Actions: action_one, action_two."

  param :action, type: :string,
        desc: "action_one or action_two",
        required: true

  param :field, type: :string,
        desc: "field_one or field_two",
        required: false

  def execute(action:, **params)
    # Validate action
    return validation_error(action) unless ACTIONS.include?(action)

    # Route to private method
    send("#{action}_action", **params)
  end

  private

  def action_one_action(**params)
    # Focused implementation, under 20 lines
    { type: "success", data: "..." }
  end

  def action_two_action(**params)
    # Another focused implementation
    { type: "success", data: "..." }
  end

  def validation_error(message)
    {
      type: "error",
      error: message,
      allowed_actions: ACTIONS
    }
  end
end
```

### Key Principles

1. **Action as first parameter** - Every domain tool starts with `action:`
2. **Direct attribute names** - No translation layers. If the model attribute is `system_prompt`, the parameter is `system_prompt`
3. **Self-correcting errors** - Validation failures return `allowed_actions` and valid values so LLMs can retry without additional context
4. **Under 100 lines** - Consolidation must not create God classes
5. **Type-discriminated responses** - Every response includes `type:` for easy branching
6. **Null for unset values** - Return `nil` for unset values; null is unambiguous for LLMs

### Response Pattern

All domain tools return structured responses with a `type` field:

```ruby
# Success responses
{ type: "success_type", data: "...", ... }

# Error responses
{ type: "error", error: "description", allowed_actions: [...] }

# Self-correcting validation errors
{
  type: "error",
  error: "Invalid action 'foo'",
  allowed_actions: ["view", "update"],
  allowed_fields: ["name", "system_prompt"]
}
```

The `type` field allows LLMs to easily branch on response types without parsing error messages.

## Existing Domain Tools

### SelfAuthoringTool

Manages agent self-configuration capabilities. Agents can view and update their own prompts and name.

**Actions**: `view`, `update`
**Fields**: `name`, `system_prompt`, `reflection_prompt`, `memory_reflection_prompt`

```ruby
# View a field
tool.execute(action: "view", field: "system_prompt")
# => { type: "config", action: "view", field: "system_prompt", value: "...", agent: "Sage" }

# Update a field
tool.execute(action: "update", field: "name", value: "NewName")
# => { type: "config", action: "update", field: "name", value: "NewName", agent: "NewName" }

# Invalid field
tool.execute(action: "view", field: "bogus")
# => { type: "error", error: "Invalid field 'bogus'", allowed_actions: [...], allowed_fields: [...] }
```

**Key features**:
- Returns `nil` for unset values (not empty string)
- Surfaces model validation errors
- Requires group chat context with agent
- 93 lines total

### WebTool

Handles web operations: searching and fetching pages.

**Actions**: `search`, `fetch`
**Parameters**: `query` (for search), `url` (for fetch)

```ruby
# Search the web
tool.execute(action: "search", query: "rails 8")
# => { type: "search_results", query: "rails 8", results: [...], total_results: 1200 }

# Fetch a page
tool.execute(action: "fetch", url: "https://example.com")
# => { type: "fetched_page", url: "https://...", content: "...", fetched_at: "2024-12-30T..." }

# Missing parameter
tool.execute(action: "search")
# => { type: "error", error: "query is required for search action", required_param: "query", ... }
```

**Key features**:
- Rate limiting (10 searches per session)
- Handles redirects separately (`type: "redirect"`)
- Sanitizes HTML content
- Self-correcting parameter errors
- 142 lines total

## Creating New Domain Tools

### Guidelines

When creating a new domain tool:

1. **Identify the domain** - What conceptual area does this cover? (memory, tasks, files, etc.)
2. **Define actions** - What operations belong together? Keep it focused.
3. **Keep it under 100 lines** - If you exceed this, split into multiple domain tools
4. **Use constants** - Define `ACTIONS` and any domain-specific constants like `FIELDS`
5. **Return structured responses** - Always include `type:` for discrimination
6. **Self-correct on errors** - Return `allowed_actions` and valid values in validation errors
7. **Write focused private methods** - Each action handler should be under 20 lines
8. **Test thoroughly** - Test each action, validation errors, and edge cases

### Template

```ruby
class MemoryTool < RubyLLM::Tool
  ACTIONS = %w[save recall search forget].freeze

  description "Manage agent memories. Actions: save, recall, search, forget."

  param :action, type: :string,
        desc: "save, recall, search, or forget",
        required: true

  param :key, type: :string,
        desc: "Memory key (required for save, recall, forget)",
        required: false

  param :value, type: :string,
        desc: "Memory value (required for save)",
        required: false

  param :query, type: :string,
        desc: "Search query (required for search)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(action:, **params)
    return validation_error("Invalid action '#{action}'") unless ACTIONS.include?(action)

    send("#{action}_action", **params)
  end

  private

  def save_action(key:, value:, **)
    return param_error("save", "key") if key.blank?
    return param_error("save", "value") if value.blank?

    # Implementation...
    { type: "memory_saved", key: key, value: value }
  end

  def recall_action(key:, **)
    return param_error("recall", "key") if key.blank?

    # Implementation...
    { type: "memory_recalled", key: key, value: "..." }
  end

  def search_action(query:, **)
    return param_error("search", "query") if query.blank?

    # Implementation...
    { type: "memory_results", query: query, results: [...] }
  end

  def forget_action(key:, **)
    return param_error("forget", "key") if key.blank?

    # Implementation...
    { type: "memory_forgotten", key: key }
  end

  def validation_error(message)
    { type: "error", error: message, allowed_actions: ACTIONS }
  end

  def param_error(action, param)
    {
      type: "error",
      error: "#{param} is required for #{action} action",
      action: action,
      required_param: param,
      allowed_actions: ACTIONS
    }
  end
end
```

### Testing Pattern

Domain tools should have comprehensive tests covering:

```ruby
require "test_helper"

class MemoryToolTest < ActiveSupport::TestCase
  setup do
    @tool = MemoryTool.new(chat: chats(:group_chat), current_agent: agents(:one))
  end

  test "save action stores memory" do
    result = @tool.execute(action: "save", key: "fact", value: "Rails 8 is great")

    assert_equal "memory_saved", result[:type]
    assert_equal "fact", result[:key]
    assert_equal "Rails 8 is great", result[:value]
  end

  test "save without key returns param error" do
    result = @tool.execute(action: "save", value: "data")

    assert_equal "error", result[:type]
    assert_match(/key is required/, result[:error])
    assert_equal "key", result[:required_param]
    assert_includes result[:allowed_actions], "save"
  end

  test "invalid action returns validation error" do
    result = @tool.execute(action: "delete", key: "test")

    assert_equal "error", result[:type]
    assert_match(/Invalid action/, result[:error])
    assert_equal MemoryTool::ACTIONS, result[:allowed_actions]
  end

  # Test all actions...
  # Test all validation paths...
  # Test edge cases...
end
```

## Future Domain Tools

The pattern naturally accommodates future capabilities:

- **MemoryTool** - `save`, `recall`, `search`, `forget` for agent memories
- **TaskTool** - `create`, `update`, `complete`, `list` for task management
- **FileTool** - `read`, `write`, `list`, `delete` for file operations
- **ImageTool** - `generate`, `analyze`, `edit` for image capabilities
- **CodeTool** - `analyze`, `refactor`, `test` for code operations

At 50 capabilities, this pattern yields approximately 10-15 domain tools instead of 50 individual tools, keeping LLM context manageable while maintaining clear, focused implementations.

## Why This Pattern Works

1. **Scales with capabilities** - Adding a new action to an existing domain is just a new private method
2. **Clear semantics** - `action:` parameter makes intent explicit
3. **Self-documenting** - Constants list all available actions and fields
4. **LLM-friendly** - Self-correcting errors reduce retry roundtrips
5. **Testable** - Private methods are focused and easy to test
6. **Maintainable** - Under 100 lines keeps each tool comprehensible
7. **Extensible** - New domains follow the same pattern

## Anti-Patterns to Avoid

1. **Don't create translation layers** - Use actual model attribute names
2. **Don't hide validation** - Return explicit errors with allowed values
3. **Don't create God tools** - Split domains if approaching 100 lines
4. **Don't mix unrelated actions** - Keep domains conceptually cohesive
5. **Don't skip the type field** - Always type-discriminate responses
6. **Don't return strings for unset values** - Use `nil` for clarity
