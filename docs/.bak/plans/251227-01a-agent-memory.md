# Agent Memory Feature - Implementation Specification

**Plan ID:** 251227-01a
**Status:** Ready for Implementation
**Date:** December 27, 2025

## Summary

Give agents persistent memory with two levels:
- **Journal** (medium-term): Timestamped entries, only last week included in prompts
- **Core** (long-term): Permanent memories, always included in prompts

Memories are private per-agent, auto-injected after system prompt, and created via tools. Admins can review memories on the agent edit page.

**Total new code: ~350 lines**

---

## 1. Database Design

### Migration

**File:** `db/migrate/[timestamp]_create_agent_memories.rb`

```ruby
class CreateAgentMemories < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_memories do |t|
      t.references :agent, null: false, foreign_key: true
      t.text :content, null: false
      t.integer :memory_type, null: false, default: 0
      t.timestamps
    end

    add_index :agent_memories, [:agent_id, :memory_type]
    add_index :agent_memories, [:agent_id, :created_at]
  end
end
```

Design rationale:
- Single table with `memory_type` enum (journal=0, core=1) rather than two tables - simpler, easier to query
- No `expires_at` column - expiry is a query concern, not a data concern (per requirements: "hard-coded backend constant")
- `content` is text, not string, to allow longer memories
- Indexes support both type-based queries and recency queries

---

## 2. Model Implementation

### AgentMemory Model

**File:** `app/models/agent_memory.rb`

```ruby
class AgentMemory < ApplicationRecord
  JOURNAL_WINDOW = 1.week

  belongs_to :agent

  enum :memory_type, { journal: 0, core: 1 }

  validates :content, presence: true, length: { maximum: 10_000 }
  validates :memory_type, presence: true

  scope :active_journal, -> { journal.where(created_at: JOURNAL_WINDOW.ago..) }
  scope :for_prompt, -> { where(memory_type: :core).or(active_journal).order(created_at: :asc) }
  scope :recent_first, -> { order(created_at: :desc) }

  def expired?
    journal? && created_at < JOURNAL_WINDOW.ago
  end
end
```

### Agent Model Extensions

**File:** `app/models/agent.rb` (additions)

Add association after `belongs_to :account`:

```ruby
has_many :memories, class_name: "AgentMemory", dependent: :destroy
```

Add method for memory injection:

```ruby
def memory_context
  active_memories = memories.for_prompt
  return nil if active_memories.empty?

  sections = []

  core_memories = active_memories.select(&:core?)
  if core_memories.any?
    sections << "## Core Memories (permanent)\n" +
                core_memories.map { |m| "- #{m.content}" }.join("\n")
  end

  journal_memories = active_memories.select(&:journal?)
  if journal_memories.any?
    sections << "## Recent Journal Entries\n" +
                journal_memories.map { |m| "- [#{m.created_at.strftime('%Y-%m-%d')}] #{m.content}" }.join("\n")
  end

  "# Your Private Memory\n\n" + sections.join("\n\n")
end
```

Update `json_attributes` to include memories count for admin UI:

```ruby
json_attributes :name, :system_prompt, :model_id, :model_label,
                :enabled_tools, :active?, :colour, :icon, :memories_count
```

Add method:

```ruby
def memories_count
  { core: memories.core.count, journal: memories.journal.count }
end
```

---

## 3. Memory Injection

The memory context needs to be injected after the system prompt but before conversation messages. This happens in `Chat#build_context_for_agent`.

**File:** `app/models/chat.rb` (modification to `system_message_for`)

```ruby
private

def system_message_for(agent)
  parts = []

  parts << (agent.system_prompt.presence || "You are #{agent.name}.")

  if (memory_context = agent.memory_context)
    parts << memory_context
  end

  parts << "You are participating in a group conversation."
  parts << "Other participants: #{participant_description(agent)}."

  { role: "system", content: parts.join("\n\n") }
end
```

This approach:
- Keeps memory private to each agent (built from `agent.memories`)
- Injects after system prompt, before conversation context
- Only includes active memories (core + recent journal)
- Self-documenting format the agent can understand

---

## 4. Tool Implementation

### SaveToJournalTool

**File:** `app/tools/save_to_journal_tool.rb`

```ruby
class SaveToJournalTool < RubyLLM::Tool
  description "Save a memory to your personal journal. Journal entries are temporary and will fade after about a week. Use this for observations, insights, or things you want to remember in the short term."

  param :content, type: :string,
        desc: "The memory to save (keep it concise, under a paragraph)",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(content:)
    return { error: "This tool only works in group conversations" } unless @current_agent

    content = content.to_s.strip
    return { error: "Content cannot be blank" } if content.blank?
    return { error: "Content too long (max 10,000 characters)" } if content.length > 10_000

    memory = @current_agent.memories.create!(
      content: content,
      memory_type: :journal
    )

    {
      success: true,
      memory_type: "journal",
      content: memory.content,
      expires_around: (memory.created_at + AgentMemory::JOURNAL_WINDOW).strftime("%Y-%m-%d")
    }
  rescue ActiveRecord::RecordInvalid => e
    { error: "Failed to save: #{e.record.errors.full_messages.join(', ')}" }
  end
end
```

### SaveToCoreTool

**File:** `app/tools/save_to_core_tool.rb`

```ruby
class SaveToCoreTool < RubyLLM::Tool
  description "Save a memory to your core identity. Core memories are permanent and define who you are. Use sparingly for fundamental beliefs, key learnings, or essential information about yourself."

  param :content, type: :string,
        desc: "The core memory to save (keep it concise and meaningful)",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(content:)
    return { error: "This tool only works in group conversations" } unless @current_agent

    content = content.to_s.strip
    return { error: "Content cannot be blank" } if content.blank?
    return { error: "Content too long (max 10,000 characters)" } if content.length > 10_000

    memory = @current_agent.memories.create!(
      content: content,
      memory_type: :core
    )

    {
      success: true,
      memory_type: "core",
      content: memory.content,
      note: "This memory is now part of your permanent identity"
    }
  rescue ActiveRecord::RecordInvalid => e
    { error: "Failed to save: #{e.record.errors.full_messages.join(', ')}" }
  end
end
```

---

## 5. Admin UI - Agent Edit Page

### Controller Updates

**File:** `app/controllers/agents_controller.rb`

Update `edit` action to include memories:

```ruby
def edit
  render inertia: "agents/edit", props: {
    agent: @agent.as_json,
    memories: memories_for_display,
    grouped_models: grouped_models,
    available_tools: tools_for_frontend,
    colour_options: Agent::VALID_COLOURS,
    icon_options: Agent::VALID_ICONS,
    account: current_account.as_json
  }
end

private

def memories_for_display
  @agent.memories.recent_first.limit(100).map do |m|
    {
      id: m.id,
      content: m.content,
      memory_type: m.memory_type,
      created_at: m.created_at.strftime("%Y-%m-%d %H:%M"),
      expired: m.expired?
    }
  end
end
```

Add destroy action for memories:

```ruby
def destroy_memory
  memory = @agent.memories.find(params[:memory_id])
  memory.destroy!
  redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory deleted"
end
```

### Routes Update

**File:** `config/routes.rb`

Update agents resource:

```ruby
resources :agents, except: [ :show, :new ] do
  member do
    delete "memories/:memory_id", action: :destroy_memory, as: :destroy_memory
  end
end
```

### Frontend Component

**File:** `app/frontend/pages/agents/edit.svelte` (additions)

Add to script section:

```javascript
import { Trash, Brain, BookOpen, Warning } from 'phosphor-svelte';
import { destroyMemoryAccountAgentPath } from '@/routes';

let { agent, memories = [], grouped_models = {}, /* ...rest */ } = $props();

function deleteMemory(memoryId) {
  if (confirm('Delete this memory permanently?')) {
    router.delete(destroyMemoryAccountAgentPath(account.id, agent.id, memoryId));
  }
}
```

Add new Card section after Tools & Capabilities card:

```svelte
<Card>
  <CardHeader>
    <CardTitle>Agent Memory</CardTitle>
    <CardDescription>
      Review and manage this agent's memories. Core memories are permanent; journal entries fade after a week.
    </CardDescription>
  </CardHeader>
  <CardContent>
    {#if memories.length === 0}
      <p class="text-sm text-muted-foreground py-4">
        This agent has no memories yet. Memories will appear here as the agent creates them using save_to_journal or save_to_core tools.
      </p>
    {:else}
      <div class="space-y-3 max-h-96 overflow-y-auto">
        {#each memories as memory (memory.id)}
          <div class="flex items-start gap-3 p-3 rounded-lg border {memory.expired ? 'opacity-50 border-dashed' : 'border-border'}">
            <div class="flex-shrink-0 mt-0.5">
              {#if memory.memory_type === 'core'}
                <Brain size={18} class="text-primary" weight="duotone" />
              {:else}
                <BookOpen size={18} class="text-muted-foreground" weight="duotone" />
              {/if}
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 mb-1">
                <span class="text-xs font-medium uppercase {memory.memory_type === 'core' ? 'text-primary' : 'text-muted-foreground'}">
                  {memory.memory_type}
                </span>
                <span class="text-xs text-muted-foreground">{memory.created_at}</span>
                {#if memory.expired}
                  <span class="text-xs text-warning flex items-center gap-1">
                    <Warning size={12} /> expired
                  </span>
                {/if}
              </div>
              <p class="text-sm whitespace-pre-wrap break-words">{memory.content}</p>
            </div>
            <button
              type="button"
              onclick={() => deleteMemory(memory.id)}
              class="flex-shrink-0 p-1 text-muted-foreground hover:text-destructive transition-colors">
              <Trash size={16} />
            </button>
          </div>
        {/each}
      </div>
    {/if}
  </CardContent>
</Card>
```

---

## 6. Implementation Checklist

### Database
- [ ] Generate migration: `rails g migration CreateAgentMemories`
- [ ] Run migration: `rails db:migrate`

### Models
- [ ] Create `app/models/agent_memory.rb`
- [ ] Add `has_many :memories` to Agent model
- [ ] Add `memory_context` method to Agent model
- [ ] Add `memories_count` to Agent json_attributes
- [ ] Update `Chat#system_message_for` to inject memories

### Tools
- [ ] Create `app/tools/save_to_journal_tool.rb`
- [ ] Create `app/tools/save_to_core_tool.rb`

### Controllers & Routes
- [ ] Update `AgentsController#edit` to include memories
- [ ] Add `AgentsController#destroy_memory`
- [ ] Update routes for memory deletion

### Frontend
- [ ] Update `agents/edit.svelte` with memory display
- [ ] Run `bin/rails js_from_routes:generate`

### Testing
- [ ] AgentMemory model tests (scopes, validations, expiry)
- [ ] Agent#memory_context tests
- [ ] SaveToJournalTool tests
- [ ] SaveToCoreTool tests
- [ ] Memory injection in context building
- [ ] Controller tests for memory display and deletion

---

## 7. Testing Strategy

### Model Tests

**File:** `test/models/agent_memory_test.rb`

```ruby
require "test_helper"

class AgentMemoryTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:basic_agent)
  end

  test "creates journal memory" do
    memory = @agent.memories.create!(content: "Test memory", memory_type: :journal)
    assert memory.journal?
    assert_not memory.expired?
  end

  test "creates core memory" do
    memory = @agent.memories.create!(content: "Core belief", memory_type: :core)
    assert memory.core?
    assert_not memory.expired?
  end

  test "for_prompt includes core memories" do
    @agent.memories.create!(content: "Core", memory_type: :core)
    assert_equal 1, @agent.memories.for_prompt.count
  end

  test "for_prompt includes recent journal entries" do
    @agent.memories.create!(content: "Recent", memory_type: :journal)
    assert_equal 1, @agent.memories.for_prompt.count
  end

  test "for_prompt excludes old journal entries" do
    memory = @agent.memories.create!(content: "Old", memory_type: :journal)
    memory.update_column(:created_at, 2.weeks.ago)
    assert_equal 0, @agent.memories.for_prompt.count
  end

  test "expired? returns true for old journal entries" do
    memory = @agent.memories.create!(content: "Old", memory_type: :journal)
    memory.update_column(:created_at, 2.weeks.ago)
    assert memory.expired?
  end

  test "expired? returns false for core memories" do
    memory = @agent.memories.create!(content: "Core", memory_type: :core)
    memory.update_column(:created_at, 1.year.ago)
    assert_not memory.expired?
  end

  test "validates content presence" do
    memory = @agent.memories.build(content: "", memory_type: :journal)
    assert_not memory.valid?
    assert_includes memory.errors[:content], "can't be blank"
  end

  test "validates content length" do
    memory = @agent.memories.build(content: "x" * 10_001, memory_type: :journal)
    assert_not memory.valid?
  end
end
```

### Agent Memory Context Tests

**File:** `test/models/agent_test.rb` (additions)

```ruby
test "memory_context returns nil when no memories" do
  agent = @account.agents.create!(name: "Empty")
  assert_nil agent.memory_context
end

test "memory_context formats core memories" do
  agent = @account.agents.create!(name: "With Memory")
  agent.memories.create!(content: "I am helpful", memory_type: :core)

  context = agent.memory_context
  assert_includes context, "Core Memories"
  assert_includes context, "I am helpful"
end

test "memory_context formats journal entries with dates" do
  agent = @account.agents.create!(name: "With Journal")
  agent.memories.create!(content: "Met a user", memory_type: :journal)

  context = agent.memory_context
  assert_includes context, "Journal Entries"
  assert_includes context, "Met a user"
  assert_match(/\d{4}-\d{2}-\d{2}/, context)
end

test "memory_context excludes expired journal entries" do
  agent = @account.agents.create!(name: "With Old Journal")
  memory = agent.memories.create!(content: "Old news", memory_type: :journal)
  memory.update_column(:created_at, 2.weeks.ago)

  assert_nil agent.memory_context
end
```

### Tool Tests

**File:** `test/tools/save_to_journal_tool_test.rb`

```ruby
require "test_helper"

class SaveToJournalToolTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:basic_agent)
    @chat = chats(:group_chat)
  end

  test "creates journal memory" do
    tool = SaveToJournalTool.new(chat: @chat, current_agent: @agent)

    result = tool.execute(content: "Today I learned something")

    assert result[:success]
    assert_equal "journal", result[:memory_type]
    assert_equal 1, @agent.memories.journal.count
  end

  test "fails without agent" do
    tool = SaveToJournalTool.new(chat: @chat, current_agent: nil)

    result = tool.execute(content: "Test")

    assert result[:error]
    assert_includes result[:error], "group conversations"
  end

  test "fails with blank content" do
    tool = SaveToJournalTool.new(chat: @chat, current_agent: @agent)

    result = tool.execute(content: "   ")

    assert result[:error]
    assert_includes result[:error], "blank"
  end
end
```

---

## 8. Code Summary

| Component | Lines | File |
|-----------|-------|------|
| Migration | 15 | `db/migrate/*_create_agent_memories.rb` |
| AgentMemory model | 25 | `app/models/agent_memory.rb` |
| Agent model additions | 25 | `app/models/agent.rb` |
| Chat model update | 15 | `app/models/chat.rb` |
| SaveToJournalTool | 40 | `app/tools/save_to_journal_tool.rb` |
| SaveToCoreTool | 40 | `app/tools/save_to_core_tool.rb` |
| Routes update | 5 | `config/routes.rb` |
| AgentsController updates | 25 | `app/controllers/agents_controller.rb` |
| edit.svelte memory UI | 60 | `app/frontend/pages/agents/edit.svelte` |
| Tests | ~100 | Various test files |
| **Total** | **~350** | |

---

## 9. Security Considerations

- **Agent isolation**: Memories are scoped via `belongs_to :agent`, enforced by loading through `@agent.memories`
- **Admin-only access**: Memory viewing/deletion requires access to agent edit page (account membership)
- **No cross-agent queries**: Tools receive `current_agent` and can only create memories for that agent
- **Content limits**: 10,000 character max prevents abuse

---

## 10. Future Considerations (Out of Scope)

- Automatic conversation consolidation job
- Shared "digital whiteboard" memories between agents
- Memory search/filtering in admin UI
- Memory export/import
- Memory editing (currently delete-only)
