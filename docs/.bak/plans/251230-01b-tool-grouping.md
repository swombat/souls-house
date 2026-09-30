# Tool Grouping Implementation Plan (Revised)

## Executive Summary

This plan addresses the original requirement (add tools for viewing/changing conversation consolidation and memory management prompts) while respecting DHH's critique of the first iteration. Instead of creating polymorphic tools with string-based dispatch and overloaded parameters, we:

1. **Keep the existing beautiful, focused tools**
2. **Extend them with optional parameters** where doing so is natural
3. **Keep web tools separate** - they do fundamentally different things
4. **Compress at the presentation layer** if token limits become a real problem

The key insight from DHH's review: the existing tools (21-86 lines each) are exemplary Rails-worthy code. We should extend them, not replace them.

---

## Architecture Overview

### What Changes

**ViewSystemPromptTool** becomes **ViewPromptTool**:
- Gains an optional `which` parameter to select which prompt to view
- Defaults to viewing system_prompt (preserving current behavior)
- Remains focused on a single responsibility: viewing

**UpdateSystemPromptTool** becomes **UpdatePromptTool**:
- Gains optional parameters for the new prompt types
- Remains focused on a single responsibility: updating
- All parameters optional except at least one must be provided

**WebSearchTool** and **WebFetchTool**: Unchanged
- They do fundamentally different things (search vs fetch)
- Merging them would require `query_or_url` which is a code smell
- Four tools is not "drowning in tools" - clarity trumps count

### What Stays the Same

- Single-responsibility tools
- Clean, focused implementations
- No string-based action dispatch
- No parameter overloading
- No translation layers between names

---

## Part 1: ViewPromptTool

### Design Rationale

The tool remains focused on one thing: viewing. The only extension is allowing selection of which prompt to view. The parameter name `which` is clear and idiomatic Ruby.

### Implementation

```ruby
class ViewPromptTool < RubyLLM::Tool

  PROMPTS = {
    "system_prompt" => :system_prompt,
    "reflection_prompt" => :reflection_prompt,
    "memory_reflection_prompt" => :memory_reflection_prompt,
    "name" => :name
  }.freeze

  description "View one of your prompts: system_prompt (default), reflection_prompt, memory_reflection_prompt, or name"

  param :which, type: :string,
        desc: "Which prompt to view: system_prompt, reflection_prompt, memory_reflection_prompt, or name",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

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

  private

  def error(msg) = { error: msg }

end
```

### Key Decisions

1. **Use actual attribute names**: `system_prompt`, `reflection_prompt`, `memory_reflection_prompt`. No translation layer. The LLM calls it what the model calls it.

2. **Default to system_prompt**: Maintains backward compatibility. Most common use case requires no parameter.

3. **Include name in response**: Always include the agent's name for context, regardless of what's being viewed.

4. **Keep it under 35 lines**: Simple, comprehensible, Rails-worthy.

---

## Part 2: UpdatePromptTool

### Design Rationale

The existing `UpdateSystemPromptTool` already demonstrates the right pattern: optional parameters for what you want to update. We simply extend this with the additional prompt types.

### Implementation

```ruby
class UpdatePromptTool < RubyLLM::Tool

  description "Update your prompts and/or name. Provide the fields you want to change."

  param :system_prompt, type: :string,
        desc: "Your new system prompt (omit to keep current)",
        required: false

  param :reflection_prompt, type: :string,
        desc: "Your new reflection prompt for conversation consolidation (omit to keep current)",
        required: false

  param :memory_reflection_prompt, type: :string,
        desc: "Your new memory reflection prompt (omit to keep current)",
        required: false

  param :name, type: :string,
        desc: "Your new name (omit to keep current)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(system_prompt: nil, reflection_prompt: nil, memory_reflection_prompt: nil, name: nil)
    return error("This tool only works in group conversations") unless @chat&.group_chat?
    return error("No current agent context") unless @current_agent

    updates = {
      system_prompt: system_prompt,
      reflection_prompt: reflection_prompt,
      memory_reflection_prompt: memory_reflection_prompt,
      name: name
    }.compact

    return error("Provide at least one field to update") if updates.empty?

    if @current_agent.update(updates)
      {
        success: true,
        updated_fields: updates.keys,
        current_values: updates.keys.index_with { |k| @current_agent.send(k) }
      }
    else
      error("Failed to update: #{@current_agent.errors.full_messages.join(', ')}")
    end
  end

  private

  def error(msg) = { error: msg }

end
```

### Key Decisions

1. **Direct attribute names as parameters**: No mapping, no translation. Parameters match model attributes exactly.

2. **Parallel structure with existing tool**: This is the same pattern as `UpdateSystemPromptTool`, just with more fields. Any Rails developer will recognize it instantly.

3. **Compact hash for updates**: Ruby's `compact` elegantly handles the "only update what's provided" pattern.

4. **Return what was updated**: The response includes both which fields changed and their new values.

---

## Part 3: Web Tools - Keep Them Separate

### Design Rationale

DHH's critique is correct: `query_or_url` is a code smell. A parameter whose meaning changes based on another parameter is wrong.

More fundamentally, searching and fetching are different operations:
- **Search**: Takes a query, returns multiple results with snippets
- **Fetch**: Takes a URL, returns a single page's content

Merging them gains nothing except a lower tool count. But tool count is not the goal - clarity is.

### Decision: No Changes to Web Tools

`WebSearchTool` and `WebFetchTool` remain as-is. They are already exemplary code:

- `WebSearchTool`: 86 lines, focused on search, handles rate limiting
- `WebFetchTool`: 61 lines, focused on fetching, handles redirects

If token limits become a genuine problem (measure first!), address it at the presentation layer by grouping tool descriptions in the prompt, not by merging implementations.

---

## Part 4: Presentation Layer Optimization (Optional)

If token limits are genuinely causing issues, group tool descriptions without merging implementations:

```ruby
# In prompt generation, group related tools:
#
# === Prompt Management ===
# view_prompt: View any of your prompts (system, reflection, memory) or name
# update_prompt: Update any of your prompts or name
#
# === Web Access ===
# web_search: Search the web, returns URLs with snippets
# web_fetch: Fetch full content from a URL
```

This reduces token usage in descriptions while keeping implementations clean and focused.

---

## Implementation Checklist

### Phase 1: Create New Tools

- [ ] Create `/app/tools/view_prompt_tool.rb` (based on design above)
- [ ] Create `/app/tools/update_prompt_tool.rb` (based on design above)

### Phase 2: Tests

- [ ] Create `/test/tools/view_prompt_tool_test.rb`
  - [ ] Test viewing system_prompt (default)
  - [ ] Test viewing reflection_prompt
  - [ ] Test viewing memory_reflection_prompt
  - [ ] Test viewing name
  - [ ] Test invalid prompt type returns clear error
  - [ ] Test requires group chat context
  - [ ] Test requires agent context
  - [ ] Test "(not set)" for nil values

- [ ] Create `/test/tools/update_prompt_tool_test.rb`
  - [ ] Test updating single field
  - [ ] Test updating multiple fields
  - [ ] Test updating all fields
  - [ ] Test requires at least one field
  - [ ] Test requires group chat context
  - [ ] Test requires agent context
  - [ ] Test validation errors bubble up

### Phase 3: Update Agent Configuration

- [ ] Create migration to update agent `enabled_tools` arrays:
  - `ViewSystemPromptTool` -> `ViewPromptTool`
  - `UpdateSystemPromptTool` -> `UpdatePromptTool`

```ruby
# db/migrate/YYYYMMDDHHMMSS_rename_prompt_tools.rb
class RenamePromptTools < ActiveRecord::Migration[8.0]
  def up
    Agent.find_each do |agent|
      next if agent.enabled_tools.blank?

      new_tools = agent.enabled_tools.map do |tool|
        case tool
        when "ViewSystemPromptTool" then "ViewPromptTool"
        when "UpdateSystemPromptTool" then "UpdatePromptTool"
        else tool
        end
      end.uniq

      agent.update_column(:enabled_tools, new_tools) if new_tools != agent.enabled_tools
    end
  end

  def down
    Agent.find_each do |agent|
      next if agent.enabled_tools.blank?

      new_tools = agent.enabled_tools.map do |tool|
        case tool
        when "ViewPromptTool" then "ViewSystemPromptTool"
        when "UpdatePromptTool" then "UpdateSystemPromptTool"
        else tool
        end
      end.uniq

      agent.update_column(:enabled_tools, new_tools) if new_tools != agent.enabled_tools
    end
  end
end
```

### Phase 4: Remove Old Tools

- [ ] Delete `/app/tools/view_system_prompt_tool.rb`
- [ ] Delete `/app/tools/update_system_prompt_tool.rb`

### Phase 5: Verification

- [ ] Run full test suite: `rails test`
- [ ] Manually test in group chat:
  - [ ] View each prompt type
  - [ ] Update each prompt type
  - [ ] Update multiple fields at once
- [ ] Verify web tools still work correctly

---

## Test Plan

### ViewPromptTool Tests

```ruby
require "test_helper"

class ViewPromptToolTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:one)
    @agent.update!(
      system_prompt: "System prompt content",
      reflection_prompt: "Reflection prompt content",
      memory_reflection_prompt: "Memory prompt content"
    )
    @chat = chats(:group_chat)
    @tool = ViewPromptTool.new(chat: @chat, current_agent: @agent)
  end

  test "views system_prompt by default" do
    result = @tool.execute

    assert_equal @agent.name, result[:name]
    assert_equal "system_prompt", result[:which]
    assert_equal "System prompt content", result[:value]
  end

  test "views system_prompt when explicitly requested" do
    result = @tool.execute(which: "system_prompt")

    assert_equal "system_prompt", result[:which]
    assert_equal "System prompt content", result[:value]
  end

  test "views reflection_prompt" do
    result = @tool.execute(which: "reflection_prompt")

    assert_equal "reflection_prompt", result[:which]
    assert_equal "Reflection prompt content", result[:value]
  end

  test "views memory_reflection_prompt" do
    result = @tool.execute(which: "memory_reflection_prompt")

    assert_equal "memory_reflection_prompt", result[:which]
    assert_equal "Memory prompt content", result[:value]
  end

  test "views name" do
    result = @tool.execute(which: "name")

    assert_equal "name", result[:which]
    assert_equal @agent.name, result[:value]
  end

  test "returns (not set) for nil values" do
    @agent.update!(system_prompt: nil)

    result = @tool.execute(which: "system_prompt")

    assert_equal "(not set)", result[:value]
  end

  test "rejects invalid prompt type" do
    result = @tool.execute(which: "invalid")

    assert_match(/Unknown prompt type/, result[:error])
    assert_match(/system_prompt/, result[:error])
  end

  test "requires group chat context" do
    tool = ViewPromptTool.new(chat: nil, current_agent: @agent)

    result = tool.execute

    assert_match(/group conversations/, result[:error])
  end

  test "requires agent context" do
    tool = ViewPromptTool.new(chat: @chat, current_agent: nil)

    result = tool.execute

    assert_match(/No current agent/, result[:error])
  end

end
```

### UpdatePromptTool Tests

```ruby
require "test_helper"

class UpdatePromptToolTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:one)
    @agent.update!(
      system_prompt: "Original system",
      reflection_prompt: "Original reflection",
      memory_reflection_prompt: "Original memory"
    )
    @chat = chats(:group_chat)
    @tool = UpdatePromptTool.new(chat: @chat, current_agent: @agent)
  end

  test "updates system_prompt" do
    result = @tool.execute(system_prompt: "New system prompt")

    assert result[:success]
    assert_includes result[:updated_fields], :system_prompt
    assert_equal "New system prompt", result[:current_values][:system_prompt]
    assert_equal "New system prompt", @agent.reload.system_prompt
  end

  test "updates reflection_prompt" do
    result = @tool.execute(reflection_prompt: "New reflection")

    assert result[:success]
    assert_includes result[:updated_fields], :reflection_prompt
    assert_equal "New reflection", @agent.reload.reflection_prompt
  end

  test "updates memory_reflection_prompt" do
    result = @tool.execute(memory_reflection_prompt: "New memory")

    assert result[:success]
    assert_includes result[:updated_fields], :memory_reflection_prompt
    assert_equal "New memory", @agent.reload.memory_reflection_prompt
  end

  test "updates name" do
    result = @tool.execute(name: "New Name")

    assert result[:success]
    assert_includes result[:updated_fields], :name
    assert_equal "New Name", @agent.reload.name
  end

  test "updates multiple fields at once" do
    result = @tool.execute(
      system_prompt: "New system",
      name: "New Name"
    )

    assert result[:success]
    assert_includes result[:updated_fields], :system_prompt
    assert_includes result[:updated_fields], :name
    assert_equal "New system", @agent.reload.system_prompt
    assert_equal "New Name", @agent.reload.name
  end

  test "requires at least one field" do
    result = @tool.execute

    assert_match(/at least one field/, result[:error])
  end

  test "requires group chat context" do
    tool = UpdatePromptTool.new(chat: nil, current_agent: @agent)

    result = tool.execute(system_prompt: "Test")

    assert_match(/group conversations/, result[:error])
  end

  test "requires agent context" do
    tool = UpdatePromptTool.new(chat: @chat, current_agent: nil)

    result = tool.execute(system_prompt: "Test")

    assert_match(/No current agent/, result[:error])
  end

  test "surfaces validation errors" do
    # Assuming name has a uniqueness validation per account
    other_agent = Agent.create!(
      account: @agent.account,
      name: "Taken Name",
      llm_model: @agent.llm_model
    )

    result = @tool.execute(name: "Taken Name")

    assert_match(/Failed to update/, result[:error])
  end

end
```

---

## Edge Cases and Error Handling

### ViewPromptTool

1. **Nil values**: Return "(not set)" rather than nil - clearer for LLMs
2. **Invalid which parameter**: Return clear error listing valid options
3. **Missing context**: Return specific error about what's missing

### UpdatePromptTool

1. **No fields provided**: Clear error message
2. **Validation failures**: Bubble up model errors with context
3. **Partial update success**: ActiveRecord handles atomicity
4. **Empty string values**: These are valid updates (clearing a prompt)

---

## Comparison With First Iteration

| Aspect | First Iteration | This Revision |
|--------|-----------------|---------------|
| Tool count | 2 (down from 4) | 4 (2 renamed, 2 unchanged) |
| String dispatch | Yes (`case action`) | No |
| Parameter overloading | Yes (`query_or_url`) | No |
| Translation layers | Yes (`PROMPT_TYPES`) | No (use actual attribute names) |
| Lines per tool | ~200 (PromptManagerTool) | ~35 (ViewPromptTool), ~45 (UpdatePromptTool) |
| Mental model | "Call this tool with action X and type Y" | "Call view to view, update to update" |

---

## Summary

This revision follows DHH's guidance:

1. **Keep tools simple and focused** - View does viewing, Update does updating
2. **No string-based action dispatch** - The tool itself is the action
3. **No parameter overloading** - Each parameter has one meaning
4. **No unnecessary translation layers** - Use attribute names directly
5. **Web tools stay separate** - They do fundamentally different things

The result is four clean, focused tools that any Rails developer would recognize as exemplary code. The user's goal (support all prompt types) is achieved, but through extension rather than consolidation.

If token limits become a genuine measured problem, address it at the presentation layer by grouping tool descriptions, not by making the implementations more complex.
