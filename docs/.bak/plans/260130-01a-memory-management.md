# Memory Management / Refinement Sessions

## Executive Summary

Add a memory refinement system that lets agents compress their own core memories via scheduled agentic sessions. The agent receives a ledger of its memories plus token budgets, then uses a polymorphic `RefinementTool` to consolidate, update, delete, and protect memories. Every mutation writes a durable audit record. Constitutional memories are immune to deletion. A recurring job triggers sessions weekly or when token budgets are exceeded.

## Architecture Overview

```
MemoryRefinementJob (weekly + threshold-triggered)
  -> dedup via content hash
  -> build refinement prompt with ledger + token stats
  -> agentic loop using agent's own model
  -> RefinementTool (polymorphic: search, consolidate, update, delete, protect, complete)
  -> all mutations create AuditLog entries
  -> complete_refinement writes summary journal memory
```

No service objects. Logic lives in AgentMemory (model) and RefinementTool (tool). The job orchestrates.

## Database Changes

### Migration 1: Add columns to agent_memories

```ruby
class AddRefinementFieldsToAgentMemories < ActiveRecord::Migration[8.0]
  def change
    add_column :agent_memories, :constitutional, :boolean, default: false, null: false
    add_column :agent_memories, :deleted_at, :datetime
    add_column :agent_memories, :content_hash, :string
    add_column :agent_memories, :token_estimate, :integer

    add_index :agent_memories, :deleted_at
    add_index :agent_memories, :content_hash
    add_index :agent_memories, :constitutional
  end
end
```

### Migration 2: Add refinement config to agents

```ruby
class AddRefinementConfigToAgents < ActiveRecord::Migration[8.0]
  def change
    add_column :agents, :core_token_budget, :integer, default: 5000
    add_column :agents, :last_refinement_at, :datetime
  end
end
```

## Model Changes

### AgentMemory

- [ ] Add soft-delete support (scope all existing queries to exclude deleted)
- [ ] Add `content_hash` callback: `before_save :compute_content_hash`
- [ ] Add `token_estimate` callback: `before_save :estimate_tokens`
- [ ] Add `constitutional` validation: cannot delete constitutional memories
- [ ] Add scopes: `active`, `deleted`, `constitutional`, `non_constitutional`

```ruby
class AgentMemory < ApplicationRecord
  JOURNAL_WINDOW = 1.week

  belongs_to :agent

  enum :memory_type, { journal: 0, core: 1 }

  validates :content, presence: true, length: { maximum: 10_000 }
  validates :memory_type, presence: true

  before_save :compute_content_hash
  before_save :estimate_tokens

  # Soft-delete: all existing scopes filter on active by default
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  scope :constitutional, -> { where(constitutional: true) }
  scope :non_constitutional, -> { where(constitutional: false) }

  # Override existing scopes to respect soft-delete
  scope :active_journal, -> { active.journal.where(created_at: JOURNAL_WINDOW.ago..) }
  scope :for_prompt, -> { active.where(memory_type: :core).or(active.active_journal).order(created_at: :asc) }
  scope :recent_first, -> { order(created_at: :desc) }

  def soft_delete!
    raise "Cannot delete constitutional memory" if constitutional?
    update!(deleted_at: Time.current)
  end

  def expired?
    journal? && created_at < JOURNAL_WINDOW.ago
  end

  def self.estimate_token_count(text)
    (text.to_s.length / 4.0).ceil
  end

  def self.dedup_for_agent!(agent)
    agent.memories.active.core
         .group(:content_hash)
         .having("COUNT(*) > 1")
         .pluck(:content_hash)
         .each do |hash|
           dupes = agent.memories.active.core.where(content_hash: hash).order(:created_at)
           dupes.offset(1).each(&:soft_delete!)
         end
  end

  private

  def compute_content_hash
    self.content_hash = Digest::SHA256.hexdigest(content.strip.downcase)
  end

  def estimate_tokens
    self.token_estimate = self.class.estimate_token_count(content)
  end
end
```

**Note on soft-delete scope change**: The existing `for_prompt` and `active_journal` scopes must be updated to chain through `active` so soft-deleted memories never appear in agent prompts. This is a behavioral change that needs careful testing.

### Agent

- [ ] Add `core_token_budget` and `last_refinement_at` attributes
- [ ] Add `core_token_usage` method
- [ ] Add `needs_refinement?` method
- [ ] Add `json_attributes` update for new fields

```ruby
# In Agent model, add:

def core_token_usage
  memories.active.core.sum(:token_estimate)
end

def needs_refinement?
  core_token_usage > (core_token_budget || 5000)
end
```

## RefinementTool

- [ ] Create `/app/tools/refinement_tool.rb`

This is a polymorphic domain tool, but it will NOT be added to agents' `enabled_tools`. It is only used during refinement sessions (injected by the job). This keeps it out of normal conversation context.

```ruby
class RefinementTool < RubyLLM::Tool

  ACTIONS = %w[search consolidate update delete protect complete].freeze

  description "Memory refinement tool. Actions: search, consolidate, update, delete, protect, complete."

  param :action, type: :string,
        desc: "search, consolidate, update, delete, protect, or complete",
        required: true

  param :query, type: :string,
        desc: "Search query (for search action)",
        required: false

  param :ids, type: :string,
        desc: "Comma-separated memory IDs (for consolidate, delete)",
        required: false

  param :id, type: :string,
        desc: "Single memory ID (for update, delete, protect)",
        required: false

  param :content, type: :string,
        desc: "New content (for consolidate, update)",
        required: false

  param :summary, type: :string,
        desc: "Refinement summary (for complete)",
        required: false

  def initialize(agent:)
    super()
    @agent = agent
    @stats = { consolidated: 0, updated: 0, deleted: 0, protected: 0 }
  end

  def execute(action:, **params)
    return validation_error("Invalid action '#{action}'") unless ACTIONS.include?(action)
    send("#{action}_action", **params)
  end

  private

  def search_action(query: nil, **)
    return param_error("search", "query") if query.blank?

    results = @agent.memories.active.core
                    .where("content ILIKE ?", "%#{query}%")
                    .order(:created_at)
                    .map { |m| memory_summary(m) }

    { type: "search_results", query: query, count: results.size, results: results }
  end

  def consolidate_action(ids: nil, content: nil, **)
    return param_error("consolidate", "ids") if ids.blank?
    return param_error("consolidate", "content") if content.blank?

    memory_ids = ids.split(",").map(&:strip).map(&:to_i)
    memories = @agent.memories.active.core.where(id: memory_ids)

    constitutional = memories.select(&:constitutional?)
    if constitutional.any?
      return { type: "error", error: "Cannot consolidate constitutional memories: #{constitutional.map(&:id).join(', ')}" }
    end

    return { type: "error", error: "No matching memories found" } if memories.empty?

    earliest = memories.minimum(:created_at)

    ActiveRecord::Base.transaction do
      new_memory = @agent.memories.create!(
        content: content.strip,
        memory_type: :core,
        created_at: earliest
      )

      memories.each do |m|
        audit_memory_change(m, "consolidate", m.content, "merged into ##{new_memory.id}")
        m.soft_delete!
      end

      audit_memory_change(new_memory, "consolidate_create", nil, new_memory.content)
      @stats[:consolidated] += memories.size
    end

    { type: "consolidated", merged_count: memory_ids.size, new_content: content }
  end

  def update_action(id: nil, content: nil, **)
    return param_error("update", "id") if id.blank?
    return param_error("update", "content") if content.blank?

    memory = @agent.memories.active.core.find_by(id: id)
    return { type: "error", error: "Memory ##{id} not found" } unless memory

    old_content = memory.content
    memory.update!(content: content.strip)
    audit_memory_change(memory, "update", old_content, memory.content)
    @stats[:updated] += 1

    { type: "updated", id: memory.id, content: memory.content }
  end

  def delete_action(id: nil, ids: nil, **)
    target_ids = if ids.present?
      ids.split(",").map(&:strip).map(&:to_i)
    elsif id.present?
      [id.to_i]
    else
      return param_error("delete", "id or ids")
    end

    memories = @agent.memories.active.core.where(id: target_ids)
    constitutional = memories.select(&:constitutional?)
    if constitutional.any?
      return { type: "error", error: "Cannot delete constitutional memories: #{constitutional.map(&:id).join(', ')}" }
    end

    memories.each do |m|
      audit_memory_change(m, "delete", m.content, nil)
      m.soft_delete!
    end
    @stats[:deleted] += memories.size

    { type: "deleted", count: memories.size }
  end

  def protect_action(id: nil, **)
    return param_error("protect", "id") if id.blank?

    memory = @agent.memories.active.core.find_by(id: id)
    return { type: "error", error: "Memory ##{id} not found" } unless memory

    memory.update!(constitutional: true)
    audit_memory_change(memory, "protect", nil, nil)
    @stats[:protected] += 1

    { type: "protected", id: memory.id, content: memory.content }
  end

  def complete_action(summary: nil, **)
    return param_error("complete", "summary") if summary.blank?

    AuditLog.create!(
      action: "memory_refinement_complete",
      auditable: @agent,
      account_id: @agent.account_id,
      data: { summary: summary, stats: @stats }
    )

    @agent.memories.create!(
      content: "Refinement session: #{summary}",
      memory_type: :journal
    )

    @agent.update!(last_refinement_at: Time.current)

    { type: "refinement_complete", summary: summary, stats: @stats }
  end

  def audit_memory_change(memory, operation, before_content, after_content)
    AuditLog.create!(
      action: "memory_refinement_#{operation}",
      auditable: memory,
      account_id: @agent.account_id,
      data: {
        agent_id: @agent.id,
        operation: operation,
        before: before_content,
        after: after_content
      }
    )
  end

  def memory_summary(m)
    {
      id: m.id,
      content: m.content,
      created_at: m.created_at.iso8601,
      tokens: m.token_estimate,
      constitutional: m.constitutional?
    }
  end

  def validation_error(message)
    { type: "error", error: message, allowed_actions: ACTIONS }
  end

  def param_error(action, param)
    { type: "error", error: "#{param} is required for #{action}", allowed_actions: ACTIONS }
  end
end
```

**Note**: This tool is ~140 lines, exceeding the 100-line guideline. This is acceptable because it is a specialized tool not loaded during normal conversations, and splitting it would fragment the atomic refinement session semantics. If needed, the audit helper and memory_summary could be extracted to AgentMemory model methods.

## MemoryRefinementJob

- [ ] Create `/app/jobs/memory_refinement_job.rb`
- [ ] Add to `config/recurring.yml`

```ruby
class MemoryRefinementJob < ApplicationJob

  queue_as :default

  retry_on RubyLLM::RateLimitError, wait: :polynomially_longer, attempts: 3
  retry_on RubyLLM::ServerError, wait: :polynomially_longer, attempts: 3

  def perform(agent_id = nil)
    if agent_id
      refine_agent(Agent.find(agent_id))
    else
      agents_needing_refinement.find_each do |agent|
        refine_agent(agent)
      rescue => e
        Rails.logger.error "Refinement failed for agent #{agent.id}: #{e.message}"
      end
    end
  end

  private

  def agents_needing_refinement
    Agent.active.where(
      "last_refinement_at IS NULL OR last_refinement_at < ?", 1.week.ago
    ).or(
      Agent.active.joins(:memories)
           .merge(AgentMemory.active.core)
           .group("agents.id")
           .having("SUM(agent_memories.token_estimate) > agents.core_token_budget")
    )
  end

  def refine_agent(agent)
    AgentMemory.dedup_for_agent!(agent)

    core_memories = agent.memories.active.core.order(:created_at)
    return if core_memories.empty?

    token_usage = agent.core_token_usage
    budget = agent.core_token_budget || 5000

    return if token_usage <= budget && agent.last_refinement_at&.> 1.week.ago

    tool = RefinementTool.new(agent: agent)
    prompt = build_refinement_prompt(agent, core_memories, token_usage, budget)

    chat = RubyLLM.chat(
      model: agent.model_id,
      provider: :openrouter,
      assume_model_exists: true
    )
    chat.with_tool(tool)
    chat.ask(prompt)
  end

  def build_refinement_prompt(agent, memories, usage, budget)
    ledger = memories.map { |m|
      flag = m.constitutional? ? " [CONSTITUTIONAL]" : ""
      "- ##{m.id} (#{m.created_at.strftime('%Y-%m-%d')}, ~#{m.token_estimate} tokens)#{flag}: #{m.content}"
    }.join("\n")

    <<~PROMPT
      # Memory Refinement Session

      You are reviewing your own core memories to reduce token usage while preserving meaning.
      This is compression, not forgetting. Merge granular memories into denser patterns and laws.

      ## Current Status
      - Core memories: #{memories.size}
      - Token usage: #{usage} tokens
      - Token budget: #{budget} tokens
      - Over budget by: #{[usage - budget, 0].max} tokens

      ## Rules
      - CONSTITUTIONAL memories cannot be deleted or consolidated. You may still create new constitutional memories.
      - Preserve your identity, values, and commitments.
      - Merge related memories into single, denser statements.
      - Tighten phrasing to save tokens without losing meaning.
      - Delete truly obsolete entries.
      - When done, call complete with a brief summary.

      ## Your Core Memory Ledger
      #{ledger}

      Begin your refinement. Use the available tools to search, consolidate, update, delete, or protect memories. Call complete when finished.
    PROMPT
  end
end
```

### recurring.yml addition

```yaml
memory_refinement:
  class: MemoryRefinementJob
  queue: default
  schedule: every monday at 4am
```

## Admin UI

- [ ] Add "Trigger Refinement" button to agent admin page
- [ ] Add "Toggle Constitutional" toggle on memory list items
- [ ] Route: `POST /admin/agents/:id/refine` -> enqueues `MemoryRefinementJob.perform_later(agent.id)`

### Controller

```ruby
# In existing admin agents controller, add:

def refine
  agent = current_account.agents.find(params[:id])
  MemoryRefinementJob.perform_later(agent.id)
  redirect_back fallback_location: admin_agent_path(agent),
                notice: "Refinement session queued"
end
```

### Route

```ruby
# In admin namespace
resources :agents do
  member do
    post :refine
  end
end
```

### Constitutional toggle

```ruby
# In admin memories controller or agent memories endpoint
def toggle_constitutional
  memory = AgentMemory.find(params[:id])
  memory.update!(constitutional: !memory.constitutional?)

  AuditLog.create!(
    action: "memory_constitutional_toggle",
    auditable: memory,
    account_id: current_account.id,
    user_id: current_user.id,
    data: { constitutional: memory.constitutional? }
  )

  redirect_back fallback_location: admin_agent_path(memory.agent)
end
```

## Token Estimation Helper

Simple heuristic, no gem needed. Lives on AgentMemory as a class method:

```ruby
def self.estimate_token_count(text)
  (text.to_s.length / 4.0).ceil
end
```

This matches OpenAI's rough 4-chars-per-token heuristic. Good enough for budget pressure without external dependencies.

## Step-by-Step Implementation Checklist

### Phase 1: Database & Model Foundation
- [ ] Create migration: add `constitutional`, `deleted_at`, `content_hash`, `token_estimate` to `agent_memories`
- [ ] Create migration: add `core_token_budget`, `last_refinement_at` to `agents`
- [ ] Run migrations
- [ ] Update `AgentMemory` model: soft-delete, content_hash, token_estimate, scopes
- [ ] Update `Agent` model: `core_token_usage`, `needs_refinement?`
- [ ] Backfill `content_hash` and `token_estimate` for existing records (rake task or migration data block)
- [ ] Write model tests for new scopes, soft-delete, constitutional guard, dedup

### Phase 2: RefinementTool
- [ ] Create `/app/tools/refinement_tool.rb`
- [ ] Write tests for each action: search, consolidate, update, delete, protect, complete
- [ ] Test constitutional protection (cannot delete/consolidate)
- [ ] Test audit log creation for each operation
- [ ] Test consolidation preserves earliest timestamp
- [ ] Test soft-delete atomicity

### Phase 3: MemoryRefinementJob
- [ ] Create `/app/jobs/memory_refinement_job.rb`
- [ ] Add to `config/recurring.yml`
- [ ] Write job tests (mock LLM calls)
- [ ] Test dedup runs before refinement
- [ ] Test threshold detection
- [ ] Test single-agent invocation (for admin trigger)

### Phase 4: Admin UI
- [ ] Add "Trigger Refinement" button + route
- [ ] Add constitutional toggle on memory items
- [ ] Add token usage display (current/budget) to agent detail page
- [ ] Add last_refinement_at display

### Phase 5: Verification & Edge Cases
- [ ] Verify soft-deleted memories don't appear in `for_prompt`
- [ ] Verify soft-deleted memories don't appear in `memories_count`
- [ ] Verify `SaveMemoryTool` still works (creates active memories)
- [ ] Verify `MemoryReflectionJob` still works (only promotes active journals)
- [ ] Test rollback scenario: restore soft-deleted memory via console/admin
- [ ] Ensure no N+1 queries in refinement prompt building

## Edge Cases & Error Handling

1. **Agent has no core memories**: Job skips, no refinement needed
2. **All memories are constitutional**: Agent can only tighten phrasing via update, cannot delete/consolidate
3. **LLM never calls complete**: The agentic loop in RubyLLM will eventually exhaust its tool-use cycles; no harm done since all mutations are individually atomic and audited
4. **Concurrent refinement**: `last_refinement_at` check prevents double-runs; if two run simultaneously, audit log captures both
5. **Content too long after consolidation**: Standard AgentMemory validation (10k max) catches this; tool returns the validation error and LLM can retry with shorter content
6. **Dedup removes a memory the agent is about to reference**: Dedup runs before the ledger is built, so the agent never sees the duplicate

## Testing Strategy

- **Unit tests**: AgentMemory (soft-delete, dedup, token estimation, constitutional guard), RefinementTool (each action)
- **Job tests**: MemoryRefinementJob with VCR cassettes or mocked LLM responses
- **Integration**: End-to-end refinement session with fixture memories, verifying audit trail and memory state
- **No Playwright needed**: This is an agent-only background feature; admin UI testing is simple button/toggle verification
