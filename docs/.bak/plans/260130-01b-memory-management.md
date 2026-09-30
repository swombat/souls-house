# Memory Management / Refinement Sessions

## Executive Summary

Add a memory refinement system that lets agents compress their own core memories via scheduled agentic sessions. The agent receives a ledger of its memories plus token budget info, then uses a polymorphic `RefinementTool` to consolidate, update, delete, and protect memories. Every mutation writes a durable audit record. Constitutional memories are immune to deletion. A recurring job triggers sessions weekly or when the token budget is exceeded.

## Architecture Overview

```
MemoryRefinementJob (weekly via recurring.yml)
  -> iterate active agents, check needs_refinement?
  -> build refinement prompt with ledger + token stats
  -> agentic loop using agent's own model
  -> RefinementTool (polymorphic: search, consolidate, update, delete, protect, complete)
  -> all mutations create AuditLog entries
  -> complete action writes summary journal memory
```

No service objects. Logic lives in AgentMemory (model) and RefinementTool (tool). The job orchestrates.

## Database Changes

### Migration 1: Add constitutional to agent_memories

```ruby
class AddConstitutionalToAgentMemories < ActiveRecord::Migration[8.0]
  def change
    add_column :agent_memories, :constitutional, :boolean, default: false, null: false
  end
end
```

### Migration 2: Add last_refinement_at to agents

```ruby
class AddLastRefinementAtToAgents < ActiveRecord::Migration[8.0]
  def change
    add_column :agents, :last_refinement_at, :datetime
  end
end
```

Two columns. No indexes. No backfill.

## Model Changes

### AgentMemory

- [ ] Add `CORE_TOKEN_BUDGET` constant
- [ ] Add `constitutional` scope
- [ ] Add `token_estimate` computed method
- [ ] Add `as_ledger_entry` for refinement prompt serialization
- [ ] Add `audit_refinement` for tool audit logging
- [ ] Add constitutional guard on `destroy!`

```ruby
class AgentMemory < ApplicationRecord
  JOURNAL_WINDOW = 1.week
  CORE_TOKEN_BUDGET = 5000

  belongs_to :agent

  enum :memory_type, { journal: 0, core: 1 }

  validates :content, presence: true, length: { maximum: 10_000 }
  validates :memory_type, presence: true

  scope :constitutional, -> { where(constitutional: true) }
  scope :non_constitutional, -> { where(constitutional: false) }

  before_destroy :prevent_constitutional_destruction

  def token_estimate
    (content.to_s.length / 4.0).ceil
  end

  def as_ledger_entry
    { id:, content:, created_at: created_at.iso8601, tokens: token_estimate, constitutional: constitutional? }
  end

  def audit_refinement(operation, before_content, after_content)
    AuditLog.create!(
      action: "memory_refinement_#{operation}",
      auditable: self,
      account_id: agent.account_id,
      data: { agent_id: agent_id, operation:, before: before_content, after: after_content }
    )
  end

  def expired?
    journal? && created_at < JOURNAL_WINDOW.ago
  end

  private

  def prevent_constitutional_destruction
    throw(:abort) if constitutional?
  end
end
```

Existing scopes (`for_prompt`, `active_journal`, `recent_first`) remain untouched.

### Agent

- [ ] Add `core_token_usage` method using SQL computation
- [ ] Add `needs_refinement?` method

```ruby
# In Agent model, add:

def core_token_usage
  memories.core.sum("CEIL(LENGTH(content) / 4.0)").to_i
end

def needs_refinement?
  return true if last_refinement_at.nil? || last_refinement_at < 1.week.ago
  core_token_usage > AgentMemory::CORE_TOKEN_BUDGET
end
```

## RefinementTool

- [ ] Create `/app/tools/refinement_tool.rb`

This is a polymorphic domain tool injected only during refinement sessions. It is never added to agents' `enabled_tools`.

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

    results = @agent.memories.core
                    .where("content ILIKE ?", "%#{query}%")
                    .order(:created_at)
                    .map(&:as_ledger_entry)

    { type: "search_results", query:, count: results.size, results: }
  end

  def consolidate_action(ids: nil, content: nil, **)
    return param_error("consolidate", "ids") if ids.blank?
    return param_error("consolidate", "content") if content.blank?

    memory_ids = ids.split(",").map(&:strip).map(&:to_i)
    memories = @agent.memories.core.where(id: memory_ids)
    return { type: "error", error: "No matching memories found" } if memories.empty?

    constitutional = memories.select(&:constitutional?)
    if constitutional.any?
      return { type: "error", error: "Cannot consolidate constitutional memories: #{constitutional.map(&:id).join(', ')}" }
    end

    earliest = memories.minimum(:created_at)

    ActiveRecord::Base.transaction do
      new_memory = @agent.memories.create!(content: content.strip, memory_type: :core, created_at: earliest)
      new_memory.audit_refinement("consolidate_create", nil, new_memory.content)

      memories.each do |m|
        m.audit_refinement("consolidate", m.content, "merged into ##{new_memory.id}")
        m.destroy!
      end

      @stats[:consolidated] += memories.size
    end

    { type: "consolidated", merged_count: memory_ids.size, new_content: content }
  end

  def update_action(id: nil, content: nil, **)
    return param_error("update", "id") if id.blank?
    return param_error("update", "content") if content.blank?

    memory = @agent.memories.core.find_by(id: id)
    return { type: "error", error: "Memory ##{id} not found" } unless memory

    old_content = memory.content
    memory.update!(content: content.strip)
    memory.audit_refinement("update", old_content, memory.content)
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

    memories = @agent.memories.core.where(id: target_ids)
    constitutional = memories.select(&:constitutional?)
    if constitutional.any?
      return { type: "error", error: "Cannot delete constitutional memories: #{constitutional.map(&:id).join(', ')}" }
    end

    memories.each do |m|
      m.audit_refinement("delete", m.content, nil)
      m.destroy!
    end
    @stats[:deleted] += memories.size

    { type: "deleted", count: memories.size }
  end

  def protect_action(id: nil, **)
    return param_error("protect", "id") if id.blank?

    memory = @agent.memories.core.find_by(id: id)
    return { type: "error", error: "Memory ##{id} not found" } unless memory

    memory.update!(constitutional: true)
    memory.audit_refinement("protect", nil, nil)
    @stats[:protected] += 1

    { type: "protected", id: memory.id, content: memory.content }
  end

  def complete_action(summary: nil, **)
    return param_error("complete", "summary") if summary.blank?

    AuditLog.create!(
      action: "memory_refinement_complete",
      auditable: @agent,
      account_id: @agent.account_id,
      data: { summary:, stats: @stats }
    )

    @agent.memories.create!(content: "Refinement session: #{summary}", memory_type: :journal)
    @agent.update!(last_refinement_at: Time.current)

    { type: "refinement_complete", summary:, stats: @stats }
  end

  def validation_error(message)
    { type: "error", error: message, allowed_actions: ACTIONS }
  end

  def param_error(action, param)
    { type: "error", error: "#{param} is required for #{action}", allowed_actions: ACTIONS }
  end
end
```

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
      Agent.active.find_each do |agent|
        next unless agent.needs_refinement?
        refine_agent(agent)
      rescue => e
        Rails.logger.error "Refinement failed for agent #{agent.id}: #{e.message}"
      end
    end
  end

  private

  def refine_agent(agent)
    core_memories = agent.memories.core.order(:created_at)
    return if core_memories.empty?

    token_usage = agent.core_token_usage
    budget = AgentMemory::CORE_TOKEN_BUDGET

    tool = RefinementTool.new(agent: agent)
    prompt = build_refinement_prompt(agent, core_memories, token_usage, budget)

    chat = RubyLLM.chat(model: agent.model_id, provider: :openrouter, assume_model_exists: true)
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
- [ ] Route: `POST /admin/agents/:id/refine` enqueues `MemoryRefinementJob.perform_later(agent.id)`

### Controller Actions

```ruby
# In existing admin agents controller:

def refine
  agent = current_account.agents.find(params[:id])
  MemoryRefinementJob.perform_later(agent.id)
  redirect_back fallback_location: admin_agent_path(agent),
                notice: "Refinement session queued"
end
```

```ruby
# Constitutional toggle -- scoped through account for authorization:

def toggle_constitutional
  agent = current_account.agents.find(params[:agent_id])
  memory = agent.memories.find(params[:id])
  memory.update!(constitutional: !memory.constitutional?)

  AuditLog.create!(
    action: "memory_constitutional_toggle",
    auditable: memory,
    account_id: current_account.id,
    user_id: current_user.id,
    data: { constitutional: memory.constitutional? }
  )

  redirect_back fallback_location: admin_agent_path(agent)
end
```

### Routes

```ruby
# In admin namespace
resources :agents do
  member do
    post :refine
  end
  resources :memories, only: [] do
    member do
      patch :toggle_constitutional
    end
  end
end
```

## Step-by-Step Implementation Checklist

### Phase 1: Database and Model Foundation
- [ ] Create migration: add `constitutional` boolean to `agent_memories`
- [ ] Create migration: add `last_refinement_at` datetime to `agents`
- [ ] Run migrations
- [ ] Add to `AgentMemory`: `CORE_TOKEN_BUDGET`, `constitutional` scope, `token_estimate`, `as_ledger_entry`, `audit_refinement`, `before_destroy` guard
- [ ] Add to `Agent`: `core_token_usage`, `needs_refinement?`
- [ ] Write model tests for constitutional guard, token estimation, `needs_refinement?`

### Phase 2: RefinementTool
- [ ] Create `/app/tools/refinement_tool.rb`
- [ ] Write tests for each action: search, consolidate, update, delete, protect, complete
- [ ] Test constitutional protection (cannot delete or consolidate)
- [ ] Test audit log creation for each operation
- [ ] Test consolidation preserves earliest timestamp
- [ ] Test destroy atomicity in consolidate

### Phase 3: MemoryRefinementJob
- [ ] Create `/app/jobs/memory_refinement_job.rb`
- [ ] Add to `config/recurring.yml`
- [ ] Write job tests (mock LLM calls)
- [ ] Test single-agent invocation (for admin trigger)
- [ ] Test iteration skips agents not needing refinement

### Phase 4: Admin UI
- [ ] Add "Trigger Refinement" button and route
- [ ] Add constitutional toggle on memory items with proper scoping
- [ ] Add token usage display (current / budget) to agent detail page
- [ ] Add `last_refinement_at` display

### Phase 5: Verification
- [ ] Verify `SaveMemoryTool` still works unchanged
- [ ] Verify `MemoryReflectionJob` still works unchanged
- [ ] Verify existing scopes (`for_prompt`, `active_journal`) are untouched
- [ ] Ensure no N+1 queries in refinement prompt building

## Edge Cases and Error Handling

1. **Agent has no core memories**: Job skips, no refinement needed.
2. **All memories are constitutional**: Agent can only tighten phrasing via update. Cannot delete or consolidate.
3. **LLM never calls complete**: The agentic loop in RubyLLM will eventually exhaust its tool-use cycles. All mutations are individually atomic and audited, so partial refinement is safe.
4. **Concurrent refinement**: `last_refinement_at` check prevents double-runs. If two run simultaneously, audit log captures both.
5. **Content too long after consolidation**: Standard AgentMemory validation (10k max) catches this. Tool returns the validation error and LLM can retry with shorter content.
6. **Restoring a deleted memory**: Read the audit log entry (`memory_refinement_delete`) and recreate from the `before` field.

## Testing Strategy

- **Unit tests**: AgentMemory (constitutional guard, token estimation, `as_ledger_entry`), RefinementTool (each action)
- **Job tests**: MemoryRefinementJob with VCR cassettes or mocked LLM responses
- **Integration**: End-to-end refinement session with fixture memories, verifying audit trail and memory state
- **No Playwright needed**: This is a background feature. Admin UI testing is simple button/toggle verification.
