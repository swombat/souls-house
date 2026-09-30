# Tool Grouping Implementation Plan

## Executive Summary

Extend the existing prompt tools to support all agent prompts (system, reflection, memory) and name. Keep web tools unchanged. This approach preserves the clean, focused tools already in place while addressing the requirement to manage all prompt types.

**Tools affected:**
- `ViewSystemPromptTool` becomes `ViewPromptTool`
- `UpdateSystemPromptTool` becomes `UpdatePromptTool`
- `WebSearchTool` and `WebFetchTool` remain unchanged

---

## ViewPromptTool

```ruby
class ViewPromptTool < RubyLLM::Tool

  VIEWABLE = %w[system_prompt reflection_prompt memory_reflection_prompt name].freeze

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
    return { error: "This tool only works in group conversations" } unless @chat&.group_chat?
    return { error: "No current agent context" } unless @current_agent
    return { error: "Unknown prompt type: #{which}. Valid types: #{VIEWABLE.join(', ')}" } unless VIEWABLE.include?(which)

    value = @current_agent.public_send(which)

    {
      name: @current_agent.name,
      which: which,
      value: value.presence || "(not set)"
    }
  end

end
```

---

## UpdatePromptTool

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
    return { error: "This tool only works in group conversations" } unless @chat&.group_chat?
    return { error: "No current agent context" } unless @current_agent

    updates = {
      system_prompt: system_prompt,
      reflection_prompt: reflection_prompt,
      memory_reflection_prompt: memory_reflection_prompt,
      name: name
    }.compact_blank

    return { error: "Provide at least one field to update" } if updates.empty?

    if @current_agent.update(updates)
      {
        success: true,
        updated_fields: updates.keys,
        current_values: updates.keys.index_with { |k| @current_agent.public_send(k) }
      }
    else
      { error: "Failed to update: #{@current_agent.errors.full_messages.join(', ')}" }
    end
  end

end
```

**Note:** Uses `compact_blank` (Rails extension) to match the old tool's behavior of rejecting empty strings.

---

## Migration

```ruby
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

---

## Implementation Checklist

### Phase 1: Create New Tools

- [ ] Create `/app/tools/view_prompt_tool.rb`
- [ ] Create `/app/tools/update_prompt_tool.rb`

### Phase 2: Tests

- [ ] Create `/test/tools/view_prompt_tool_test.rb`
  - [ ] Views system_prompt by default
  - [ ] Views each prompt type explicitly
  - [ ] Returns "(not set)" for nil values
  - [ ] Rejects invalid prompt type with helpful error
  - [ ] Requires group chat context
  - [ ] Requires agent context

- [ ] Create `/test/tools/update_prompt_tool_test.rb`
  - [ ] Updates single field
  - [ ] Updates multiple fields at once
  - [ ] Rejects empty strings (matching old behavior)
  - [ ] Requires at least one field
  - [ ] Requires group chat context
  - [ ] Requires agent context
  - [ ] Surfaces validation errors

### Phase 3: Migration

- [ ] Create migration `db/migrate/YYYYMMDDHHMMSS_rename_prompt_tools.rb`
- [ ] Run migration

### Phase 4: Cleanup

- [ ] Delete `/app/tools/view_system_prompt_tool.rb`
- [ ] Delete `/app/tools/update_system_prompt_tool.rb`

### Phase 5: Verification

- [ ] Run full test suite: `rails test`
- [ ] Manual verification in group chat

---

## Tests

### ViewPromptToolTest

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
    @agent.update!(reflection_prompt: nil)

    result = @tool.execute(which: "reflection_prompt")

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

### UpdatePromptToolTest

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
    result = @tool.execute(system_prompt: "New system", name: "New Name")

    assert result[:success]
    assert_includes result[:updated_fields], :system_prompt
    assert_includes result[:updated_fields], :name
    assert_equal "New system", @agent.reload.system_prompt
    assert_equal "New Name", @agent.reload.name
  end

  test "rejects empty strings" do
    result = @tool.execute(system_prompt: "")

    assert_match(/at least one field/, result[:error])
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

## Design Decisions

1. **Use `VIEWABLE` array instead of hash** - The keys and values were identical. A simple array with `public_send` is cleaner.

2. **Use `compact_blank` instead of `compact`** - Matches the old tool's behavior of rejecting empty strings. An empty string is not a meaningful update.

3. **Keep the tool rename** - `ViewPromptTool` is cleaner than `ViewSystemPromptTool` that happens to also view other prompts. The migration cost is minimal.

4. **Web tools unchanged** - They do fundamentally different things. Merging them would require `query_or_url` which is a code smell.
