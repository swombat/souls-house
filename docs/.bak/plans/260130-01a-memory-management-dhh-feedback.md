# DHH Review: Memory Management / Refinement Sessions

## Overall Assessment

This spec is **solidly architected** and clearly written by someone who understands The Rails Way. No service objects, logic in models and tools, job as orchestrator -- all correct instincts. But it over-engineers in several places: soft-delete machinery, a dedup system that solves a problem the refinement agent itself could handle, unnecessary database columns, and a query in the job that is trying too hard. The bones are right. The flesh needs trimming.

## Critical Issues

### 1. Soft-delete is enterprise Java thinking

`deleted_at`, the `active` scope, rewriting every existing scope to chain through `active` -- this is the Paranoia gem pattern. It is a well-known source of bugs in Rails applications. DHH himself has spoken against soft-delete as a default pattern. The spec even acknowledges the risk: "behavioral change that needs careful testing."

You do not need soft-delete. You need audit logs, which you already have. When the agent deletes a memory, **actually delete it**. The audit log preserves the before-content. If you ever need to restore, you read the audit log and recreate. This eliminates:

- The `deleted_at` column
- The `active` scope
- Rewriting `for_prompt` and `active_journal`
- The entire "verify soft-deleted memories don't appear" test category
- The `soft_delete!` method
- The index on `deleted_at`

Replace `soft_delete!` with `destroy!` and trust your audit trail. That is what it is for.

### 2. `content_hash` and `dedup_for_agent!` are over-engineering

You are building a dedup system -- a `content_hash` column, an index, a `before_save` callback, and a class method that does grouped queries -- to solve a problem that the LLM refinement agent can handle itself. The agent already sees the full ledger. If two memories say the same thing, the agent will consolidate them. That is literally what refinement is for.

Drop:
- `content_hash` column and index
- `compute_content_hash` callback
- `dedup_for_agent!` class method
- The dedup step in the job

If you find duplicates are a real problem in practice, add dedup later. YAGNI until proven otherwise.

### 3. `token_estimate` column is premature storage

You are storing a derived value (`content.length / 4.0 .ceil`) in a column, adding a `before_save` callback, and indexing/summing it. This value is trivially computable on the fly:

```ruby
def token_estimate
  (content.to_s.length / 4.0).ceil
end
```

For the budget check in `needs_refinement?`, you can compute it from content length directly in SQL:

```ruby
def core_token_usage
  memories.core.sum("CEIL(LENGTH(content) / 4.0)").to_i
end
```

No column needed. No callback needed. No backfill task needed. One less thing to get stale.

### 4. The `agents_needing_refinement` query is overcooked

The `.or()` with a `joins/merge/group/having` subquery is fragile SQL gymnastics. Simplify. The job runs weekly. Just iterate active agents and check cheaply:

```ruby
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
```

This runs once a week. N+1 on a weekly batch job for a handful of agents is not a problem. Clarity beats cleverness.

## Improvements Needed

### 5. `core_token_budget` column on agents is premature configuration

You are adding a per-agent configurable budget column. How many agents actually need a different budget? Start with a constant:

```ruby
class AgentMemory < ApplicationRecord
  CORE_TOKEN_BUDGET = 5000
end
```

If you later need per-agent budgets, add the column then. The migration, the nil-check fallback (`core_token_budget || 5000`), and the admin UI for it are all waste right now.

### 6. The `constitutional` index is unnecessary

You have `add_index :agent_memories, :constitutional`. Boolean columns with low cardinality are terrible index candidates. Postgres will almost never use this index. Remove it.

### 7. RefinementTool at 140 lines with a self-justification note

The spec says "This is acceptable because..." -- if you have to justify the length, the code is telling you something. The `audit_memory_change` private method and `memory_summary` do not belong on the tool. They belong on `AgentMemory`:

```ruby
# On AgentMemory
def audit_refinement(operation, before_content, after_content)
  AuditLog.create!(
    action: "memory_refinement_#{operation}",
    auditable: self,
    account_id: agent.account_id,
    data: { agent_id: agent_id, operation:, before: before_content, after: after_content }
  )
end

def as_ledger_entry
  { id:, content:, created_at: created_at.iso8601, tokens: token_estimate, constitutional: constitutional? }
end
```

This drops the tool to under 100 lines and puts data-formatting logic where it belongs -- on the model.

### 8. `toggle_constitutional` controller action does not scope to account

```ruby
memory = AgentMemory.find(params[:id])
```

This is an authorization hole. Must be scoped:

```ruby
memory = current_account.agents.find(params[:agent_id]).memories.find(params[:id])
```

### 9. The `for_prompt` scope rewrite is fragile

The spec rewrites `for_prompt` as `active.where(memory_type: :core).or(active.active_journal)`. But the current `for_prompt` uses the enum scope `.core` which is cleaner. With soft-delete removed (per issue #1), this concern disappears entirely. The existing scope stays untouched.

### 10. The `last_refinement_at` double-check in `refine_agent` is redundant

The job's `perform` already filters via `agents_needing_refinement` (or with my simplification, `needs_refinement?`). Then `refine_agent` checks again: `return if token_usage <= budget && agent.last_refinement_at&.> 1.week.ago`. Pick one place for the guard. The method should trust its caller, or the caller should not filter. Having both is defensive programming that muddies intent.

## What Works Well

- **No service objects.** The job orchestrates, the tool acts, the model holds state. Correct.
- **Polymorphic tool pattern** matches the existing codebase (`action:` param routing to private methods).
- **Audit trail on every mutation** is the right instinct and makes soft-delete unnecessary.
- **The refinement prompt** is well-structured -- clear rules, a ledger, and explicit instructions.
- **`retry_on` for LLM errors** is proper Rails job hygiene.
- **Constitutional protection** is a clean domain concept that earns its place.
- **The tool is not added to `enabled_tools`** -- injected only during refinement. Smart separation.
- **The checklist and edge cases section** shows real engineering discipline.

## Simplified Migration

After applying all feedback above, the migration shrinks to:

```ruby
class AddRefinementFieldsToAgentMemories < ActiveRecord::Migration[8.0]
  def change
    add_column :agent_memories, :constitutional, :boolean, default: false, null: false
  end
end
```

```ruby
class AddLastRefinementAtToAgents < ActiveRecord::Migration[8.0]
  def change
    add_column :agents, :last_refinement_at, :datetime
  end
end
```

Two columns instead of six. No indexes. No backfill task.

## Simplified AgentMemory Additions

```ruby
# Add to existing model -- no scope changes, no callbacks
CORE_TOKEN_BUDGET = 5000

scope :constitutional, -> { where(constitutional: true) }

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
```

## Summary

The spec's instincts are right but it reaches for infrastructure (soft-delete, content hashing, token storage, complex queries) where simplicity would serve better. Strip it back to: one boolean column, one datetime column, compute everything else on the fly, delete means delete, and trust the audit log. The feature will ship faster, have fewer edge cases, and be easier to maintain.
