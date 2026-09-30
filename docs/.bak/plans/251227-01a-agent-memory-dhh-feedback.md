# DHH Code Review: Agent Memory Implementation Spec

**Spec:** `/docs/plans/251227-01a-agent-memory.md`
**Reviewer:** DHH Standards Review
**Date:** December 27, 2025

---

## Overall Assessment

This is a solid, Rails-worthy spec. The design shows restraint and follows the fat model, skinny controller philosophy admirably. The single-table design with an enum is the correct choice. The scopes are expressive. The tools follow the existing patterns. There are a few areas where complexity has crept in unnecessarily, and a couple of places where the code fights Rails rather than flowing with it. These are easily remedied.

**Verdict:** Approved with minor revisions. This would not embarrass you in Rails core.

---

## Critical Issues

### 1. Duplicated Validation Logic in Tools

The tools duplicate validation logic that already exists in the model:

```ruby
# In SaveToJournalTool
return { error: "Content cannot be blank" } if content.blank?
return { error: "Content too long (max 10,000 characters)" } if content.length > 10_000
```

This is a code smell. The model already validates:

```ruby
validates :content, presence: true, length: { maximum: 10_000 }
```

**The Fix:** Let the model do its job. The rescue block already handles `ActiveRecord::RecordInvalid`. Remove the redundant checks. Trust Rails.

---

## Improvements Needed

### 2. The `memory_context` Method is Too Long

The `memory_context` method in Agent spans 18 lines with manual array building and conditional logic. This is not terrible, but it could be more expressive.

**Before:**
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

**After:**
```ruby
def memory_context
  return nil if memories.for_prompt.empty?

  [
    core_memory_section,
    journal_memory_section
  ].compact.join("\n\n").then { |s| "# Your Private Memory\n\n#{s}" }
end

private

def core_memory_section
  core = memories.for_prompt.select(&:core?)
  return unless core.any?

  "## Core Memories (permanent)\n" + core.map { |m| "- #{m.content}" }.join("\n")
end

def journal_memory_section
  journal = memories.for_prompt.select(&:journal?)
  return unless journal.any?

  "## Recent Journal Entries\n" + journal.map { |m| "- [#{m.created_at.strftime('%Y-%m-%d')}] #{m.content}" }.join("\n")
end
```

This is more readable, each method does one thing, and the main method reads as a table of contents.

**Alternative (even simpler):** Consider whether you need both sections at all. If the formatting is identical except for the header, extract a single method that takes the type as a parameter.

### 3. The `for_prompt` Scope Queries Twice

```ruby
scope :for_prompt, -> { where(memory_type: :core).or(active_journal).order(created_at: :asc) }
```

Then in `memory_context`, you call `select(&:core?)` and `select(&:journal?)` on the loaded result. This is fine for small datasets, but you could avoid the Ruby-side filtering by loading core and journal separately if you prefer clarity:

```ruby
def memory_context
  return nil unless memories.for_prompt.exists?

  sections = []
  sections << format_memories("Core Memories (permanent)", memories.core)
  sections << format_memories("Recent Journal Entries", memories.active_journal)
  sections.compact.join("\n\n").presence&.then { |s| "# Your Private Memory\n\n#{s}" }
end
```

However, the original approach is acceptable for typical memory counts. This is a minor style preference, not a requirement.

### 4. Simplify the Tools

The two tools are 90% identical. This is not DRY. Consider a base class or a single tool with a `type` parameter.

**Option A: Single Tool with Type Parameter**

```ruby
class SaveMemoryTool < RubyLLM::Tool
  description "Save a memory. Use 'journal' for short-term observations (fades after a week) or 'core' for permanent identity memories."

  param :content, type: :string, desc: "The memory to save", required: true
  param :memory_type, type: :string, desc: "Either 'journal' or 'core'", required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @current_agent = current_agent
  end

  def execute(content:, memory_type:)
    return error("This tool only works in group conversations") unless @current_agent
    return error("memory_type must be 'journal' or 'core'") unless %w[journal core].include?(memory_type)

    memory = @current_agent.memories.create!(content: content.to_s.strip, memory_type: memory_type)
    success_response(memory)
  rescue ActiveRecord::RecordInvalid => e
    error("Failed to save: #{e.record.errors.full_messages.join(', ')}")
  end

  private

  def error(msg) = { error: msg }

  def success_response(memory)
    { success: true, memory_type: memory.memory_type, content: memory.content }
  end
end
```

**Option B: Keep Two Tools, Extract Shared Logic**

If you want separate tools for better LLM discoverability, at least extract a concern or base class:

```ruby
module MemoryToolBehavior
  extend ActiveSupport::Concern

  included do
    param :content, type: :string, desc: "The memory to save", required: true
  end

  def initialize(chat: nil, current_agent: nil)
    super()
    @current_agent = current_agent
  end

  def save_memory(content:, memory_type:)
    return { error: "This tool only works in group conversations" } unless @current_agent

    memory = @current_agent.memories.create!(content: content.to_s.strip, memory_type: memory_type)
    { success: true, memory_type: memory.memory_type, content: memory.content }
  rescue ActiveRecord::RecordInvalid => e
    { error: "Failed to save: #{e.record.errors.full_messages.join(', ')}" }
  end
end
```

**My recommendation:** Go with Option A. One tool, one concept. The LLM can handle choosing the type. Two tools that do almost the same thing is unnecessary complexity.

### 5. The Controller Memory Deletion Action

```ruby
def destroy_memory
  memory = @agent.memories.find(params[:memory_id])
  memory.destroy!
  redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory deleted"
end
```

This is fine, but consider whether you need a separate action at all. A more RESTful approach would be a nested `AgentMemoriesController`:

```ruby
# routes.rb
resources :agents, except: [:show, :new] do
  resources :memories, only: [:destroy], controller: 'agent_memories'
end

# app/controllers/agent_memories_controller.rb
class AgentMemoriesController < ApplicationController
  before_action :set_agent

  def destroy
    @agent.memories.find(params[:id]).destroy!
    redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory deleted"
  end

  private

  def set_agent
    @agent = current_account.agents.find(params[:agent_id])
  end
end
```

However, for a single action, the inline approach is pragmatic. This is a minor point. Either is acceptable.

### 6. The `memories_count` Method

```ruby
def memories_count
  { core: memories.core.count, journal: memories.journal.count }
end
```

This fires two SQL queries. Consider using a single grouped count:

```ruby
def memories_count
  counts = memories.group(:memory_type).count
  { core: counts["core"] || 0, journal: counts["journal"] || 0 }
end
```

One query instead of two. Small optimization, but it demonstrates respect for the database.

---

## What Works Well

1. **Single table with enum** - The right choice. No unnecessary complexity.

2. **Scopes are expressive** - `for_prompt`, `active_journal`, `recent_first` read well.

3. **The migration is clean** - Good indexes, sensible defaults, no cruft.

4. **Memory injection in Chat#system_message_for** - The approach of modifying the existing method is correct. No new abstractions needed.

5. **Security model** - Loading through associations (`@agent.memories`) is the Rails way. No complex authorization layer required.

6. **The tests** - Good coverage of the key behaviors. Tests tell the story of what the code should do.

7. **Following existing patterns** - The tools match `UpdateSystemPromptTool` in structure. Consistency matters.

---

## Summary of Required Changes

| Priority | Issue | Fix |
|----------|-------|-----|
| High | Duplicated validation in tools | Remove; let model validate |
| Medium | Two nearly-identical tools | Merge into one `SaveMemoryTool` |
| Medium | `memory_context` too long | Extract private helper methods |
| Low | `memories_count` fires two queries | Use grouped count |
| Low | Inline destroy action vs nested controller | Optional; current approach acceptable |

---

## Final Verdict

This spec demonstrates good Rails instincts. The mistakes are minor - a bit of duplication, a method that got away from you, the usual temptations. The bones are strong.

Make the changes above, and this is production-ready. The design will serve you well as you extend it.

**Grade: B+** (A- with the suggested revisions)
