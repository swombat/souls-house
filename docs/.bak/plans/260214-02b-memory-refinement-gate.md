# Gate 4: Memory Refinement Session Circuit Breaker

**Date**: 2026-02-14
**Status**: Ready for implementation
**Complexity**: Low-medium
**Requirements**: `/docs/requirements/260214-02-memory-refinement-gate.md`
**Previous iteration**: `/docs/plans/260214-02a-memory-refinement-gate.md`
**DHH feedback applied**: `/docs/plans/260214-02a-memory-refinement-gate-dhh-feedback.md`

## Executive Summary

Add a post-session circuit breaker to the memory refinement process. After a refinement session completes, compare total core memory token mass before vs after. If more than a configurable threshold was cut in a single session, automatically roll back all changes using the existing audit trail.

No new gems or npm packages. One migration (a single column). Every piece of infrastructure needed -- soft-delete, audit trail, token counting -- already exists.

## Changes from First Iteration

1. `rollback_session!` decomposed into named private methods: `reverse_session_mutations!`, `reverse_mutation`, `reverse_consolidation`, `record_rollback_audit!`, `record_rollback_journal!`
2. Entire rollback wrapped in `ActiveRecord::Base.transaction`
3. `for_refinement_session` scope added to `AuditLog` -- raw SQL moved out of the tool
4. `FIELD_COERCIONS` map in `SelfAuthoringTool` replaces inline ternary
5. `pre_session_mass` alias dropped from the job -- `token_usage` passed directly
6. Combined integration test added (consolidate + update + delete in one session, then rollback)
7. Test helper extracted for repeated circuit-breaker setup pattern

## Architecture Overview

```
MemoryRefinementJob#refine_agent
  |
  |-- snapshot token_usage = agent.core_token_usage
  |-- generate session_id = SecureRandom.uuid
  |-- pass both to RefinementTool.new(agent:, session_id:, pre_session_mass: token_usage)
  |
  |-- LLM agentic loop (search, consolidate, update, delete, protect)
  |     each mutation audit log includes session_id in data JSON
  |
  |-- agent calls complete_action
        |-- check: new_mass / pre_session_mass < threshold?
        |   YES -> rollback_session! -> journal memory + rollback audit log
        |   NO  -> normal completion (existing behavior)
```

## Step-by-Step Implementation

### Step 1: Migration -- add `refinement_threshold` to agents

- [ ] Generate migration: `rails generate migration AddRefinementThresholdToAgents`

```ruby
class AddRefinementThresholdToAgents < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :refinement_threshold, :float
  end

end
```

No default in the database. The default lives in the model. A `nil` value means "use the global default."

### Step 2: Agent model -- threshold accessor with fallback

- [ ] Add `DEFAULT_REFINEMENT_THRESHOLD` constant and `effective_refinement_threshold` method to `Agent`

In `/app/models/agent.rb`:

```ruby
DEFAULT_REFINEMENT_THRESHOLD = 0.75

validates :refinement_threshold,
          numericality: { greater_than: 0, less_than_or_equal_to: 1 },
          allow_nil: true

def effective_refinement_threshold
  refinement_threshold || DEFAULT_REFINEMENT_THRESHOLD
end
```

### Step 3: AuditLog -- add `for_refinement_session` scope

- [ ] Add scope to `AuditLog`

In `/app/models/audit_log.rb`:

```ruby
scope :for_refinement_session, ->(session_id) {
  where("action LIKE 'memory_refinement_%' AND data->>'session_id' = ?", session_id)
}
```

This keeps raw SQL JSON operators where they belong -- on the model that owns the data. The tool consumes the scope.

### Step 4: SelfAuthoringTool -- add `refinement_threshold` with `FIELD_COERCIONS`

- [ ] Add `refinement_threshold` to `FIELDS` array
- [ ] Add `FIELD_COERCIONS` map for type conversion
- [ ] Update `default_for` and `description`

In `/app/tools/self_authoring_tool.rb`:

```ruby
FIELDS = %w[
  name
  system_prompt
  reflection_prompt
  memory_reflection_prompt
  refinement_threshold
].freeze

FIELD_COERCIONS = {
  "refinement_threshold" => :to_f
}.freeze

description "View or update your configuration. Actions: view, update. " \
            "Fields: name, system_prompt, reflection_prompt, memory_reflection_prompt, refinement_threshold."

param :field, type: :string,
      desc: "name, system_prompt, reflection_prompt, memory_reflection_prompt, or refinement_threshold",
      required: true
```

Update `default_for`:

```ruby
def default_for(field)
  case field
  when "reflection_prompt"
    ConsolidateConversationJob::EXTRACTION_PROMPT
  when "memory_reflection_prompt"
    MemoryReflectionJob::REFLECTION_PROMPT
  when "refinement_threshold"
    Agent::DEFAULT_REFINEMENT_THRESHOLD
  end
end
```

Update `update_field` to use the coercions map:

```ruby
def update_field(field, value)
  return validation_error("value required for update") if value.blank?

  coerced = FIELD_COERCIONS[field] ? value.public_send(FIELD_COERCIONS[field]) : value

  if @current_agent.update(field => coerced)
    {
      type: "config",
      action: "update",
      field: field,
      value: @current_agent.public_send(field),
      agent: @current_agent.name
    }
  else
    {
      type: "error",
      error: @current_agent.errors.full_messages.join(", "),
      field: field
    }
  end
end
```

The `FIELD_COERCIONS` map is declarative. When the next numeric field arrives, add one line to the hash.

### Step 5: AgentMemory -- add `session_id:` to `audit_refinement`

- [ ] Add `session_id:` keyword argument to `audit_refinement`

In `/app/models/agent_memory.rb`:

```ruby
def audit_refinement(operation, before_content, after_content, session_id: nil)
  AuditLog.create!(
    action: "memory_refinement_#{operation}",
    auditable: self,
    account_id: agent.account_id,
    data: {
      agent_id: agent_id,
      session_id: session_id,
      operation: operation,
      before: before_content,
      after: after_content
    }
  )
end
```

The `session_id: nil` default ensures backward compatibility.

### Step 6: RefinementTool -- session context, circuit breaker, decomposed rollback

- [ ] Update `initialize` to accept `session_id:` and `pre_session_mass:`
- [ ] Include `session_id` in all audit log `data` hashes
- [ ] Add circuit breaker check in `complete_action`
- [ ] Add decomposed rollback private methods wrapped in a transaction

In `/app/tools/refinement_tool.rb`:

**Constructor:**

```ruby
def initialize(agent:, session_id: nil, pre_session_mass: nil)
  super()
  @agent = agent
  @session_id = session_id
  @pre_session_mass = pre_session_mass
  @stats = { consolidated: 0, updated: 0, deleted: 0, protected: 0 }
end
```

**Pass `session_id` through to audit logs.** Three places:

1. `consolidate_action` -- add `session_id: @session_id` to the `AuditLog.create!` data hash:

```ruby
AuditLog.create!(
  action: "memory_refinement_consolidate",
  auditable: new_memory,
  account_id: @agent.account_id,
  data: {
    agent_id: @agent.id,
    session_id: @session_id,
    operation: "consolidate",
    merged: merged,
    result: { id: new_memory.id, content: new_memory.content }
  }
)
```

2. `update_action` and `delete_action` -- pass `session_id:` through to `audit_refinement`:

```ruby
def update_action(id: nil, content: nil, **)
  # ... existing validation ...
  memory.update!(content: content.strip)
  memory.audit_refinement("update", old_content, memory.content, session_id: @session_id)
  @stats[:updated] += 1
  { type: "updated", id: memory.id, content: memory.content }
end

def delete_action(id: nil, **)
  # ... existing validation ...
  memory.audit_refinement("delete", memory.content, nil, session_id: @session_id)
  memory.discard!
  @stats[:deleted] += 1
  { type: "deleted", id: memory.id }
end

def protect_action(id: nil, **)
  # ... existing validation ...
  memory.update!(constitutional: true)
  memory.audit_refinement("protect", nil, nil, session_id: @session_id)
  @stats[:protected] += 1
  { type: "protected", id: memory.id, content: memory.content }
end
```

**Circuit breaker in `complete_action`:**

```ruby
def complete_action(summary: nil, **)
  return param_error("complete", "summary") if summary.blank?

  if circuit_breaker_tripped?
    rollback_session!
    return {
      type: "refinement_rolled_back",
      summary: summary,
      stats: @stats,
      reason: "Session exceeded maximum allowed compression " \
              "(#{(@agent.effective_refinement_threshold * 100).to_i}% retention threshold)"
    }
  end

  AuditLog.create!(
    action: "memory_refinement_complete",
    auditable: @agent,
    account_id: @agent.account_id,
    data: { session_id: @session_id, summary: summary, stats: @stats }
  )

  @agent.memories.create!(content: "Refinement session: #{summary}", memory_type: :journal)
  @agent.update!(last_refinement_at: Time.current)

  { type: "refinement_complete", summary: summary, stats: @stats }
end
```

**Decomposed private methods:**

```ruby
def circuit_breaker_tripped?
  return false unless @pre_session_mass && @pre_session_mass > 0

  new_mass = @agent.core_token_usage
  ratio = new_mass.to_f / @pre_session_mass
  ratio < @agent.effective_refinement_threshold
end

def rollback_session!
  ActiveRecord::Base.transaction do
    reverse_session_mutations!
    record_rollback_audit!
    record_rollback_journal!
    @agent.update!(last_refinement_at: Time.current)
  end
end

def reverse_session_mutations!
  session_audit_logs.each { |log| reverse_mutation(log) }
end

def reverse_mutation(log)
  case log.action
  when "memory_refinement_delete"
    AgentMemory.with_discarded.find_by(id: log.auditable_id)&.undiscard!
  when "memory_refinement_update"
    memory = AgentMemory.find_by(id: log.auditable_id)
    memory&.update!(content: log.data["before"]) if log.data["before"]
  when "memory_refinement_consolidate"
    reverse_consolidation(log)
  when "memory_refinement_protect"
    AgentMemory.find_by(id: log.auditable_id)&.update!(constitutional: false)
  end
end

def reverse_consolidation(log)
  AgentMemory.find_by(id: log.data.dig("result", "id"))&.discard!
  log.data["merged"]&.each do |original|
    AgentMemory.with_discarded.find_by(id: original["id"])&.undiscard!
  end
end

def record_rollback_audit!
  AuditLog.create!(
    action: "memory_refinement_rollback",
    auditable: @agent,
    account_id: @agent.account_id,
    data: {
      session_id: @session_id,
      pre_session_mass: @pre_session_mass,
      post_session_mass: @agent.core_token_usage,
      threshold: @agent.effective_refinement_threshold,
      stats: @stats
    }
  )
end

def record_rollback_journal!
  @agent.memories.create!(
    content: "Refinement session rolled back: compression exceeded " \
             "#{(@agent.effective_refinement_threshold * 100).to_i}% retention threshold. " \
             "All changes from this session have been reversed to protect memory integrity.",
    memory_type: :journal
  )
end

def session_audit_logs
  AuditLog.for_refinement_session(@session_id).order(created_at: :desc)
end
```

Each method does one thing and has a clear name. The transaction in `rollback_session!` guarantees atomicity -- a partial rollback is worse than no rollback.

Note: `session_audit_logs` processes in reverse chronological order so dependent operations unwind cleanly. Protect actions are reversed because the entire session is suspect. `last_refinement_at` is updated even on rollback to prevent immediate re-triggering on the next sweep.

### Step 7: MemoryRefinementJob -- snapshot mass and generate session_id

- [ ] Update `refine_agent` to generate `session_id` and pass `token_usage` directly

In `/app/jobs/memory_refinement_job.rb`:

```ruby
def refine_agent(agent)
  core_memories = agent.memories.core.order(:created_at)
  return if core_memories.empty?

  token_usage = agent.core_token_usage
  budget = AgentMemory::CORE_TOKEN_BUDGET

  unless agent_consents_to_refinement?(agent, core_memories, token_usage, budget)
    Rails.logger.info "[Refinement] Agent #{agent.id} (#{agent.name}) declined refinement"
    return
  end

  session_id = SecureRandom.uuid
  tool = RefinementTool.new(agent: agent, session_id: session_id, pre_session_mass: token_usage)
  prompt = build_refinement_prompt(agent, core_memories, token_usage, budget)

  chat_for(agent).with_tool(tool).ask(prompt)

  Rails.logger.info "[Refinement] Agent #{agent.id} (#{agent.name}) complete: #{tool.stats.inspect}"
end
```

The `token_usage` variable already exists and represents pre-session mass. The keyword argument name documents its meaning. No alias needed.

## Testing Strategy

### Test Helper

- [ ] Extract shared circuit-breaker setup into a helper

In `/test/tools/refinement_tool_test.rb`:

```ruby
private

def tool_with_circuit_breaker(threshold: 1.0)
  pre_mass = @agent.core_token_usage
  @agent.update!(refinement_threshold: threshold)
  RefinementTool.new(
    agent: @agent,
    session_id: "test-#{SecureRandom.hex(4)}",
    pre_session_mass: pre_mass
  )
end
```

### RefinementTool Tests (`/test/tools/refinement_tool_test.rb`)

- [ ] **Circuit breaker triggers on excessive compression**

```ruby
test "complete rolls back when compression exceeds threshold" do
  m1 = @agent.memories.create!(content: "A" * 400, memory_type: :core)
  m2 = @agent.memories.create!(content: "B" * 400, memory_type: :core)

  tool = tool_with_circuit_breaker

  tool.execute(action: "delete", id: m1.id.to_s)
  tool.execute(action: "delete", id: m2.id.to_s)

  result = tool.execute(action: "complete", summary: "Deleted everything")

  assert_equal "refinement_rolled_back", result[:type]
  assert_not m1.reload.discarded?
  assert_not m2.reload.discarded?
end
```

- [ ] **Circuit breaker does not trigger within threshold**

```ruby
test "complete succeeds when compression is within threshold" do
  @agent.memories.create!(content: "A" * 400, memory_type: :core)
  @agent.memories.create!(content: "B" * 400, memory_type: :core)
  tiny = @agent.memories.create!(content: "C" * 20, memory_type: :core)

  pre_mass = @agent.core_token_usage
  tool = RefinementTool.new(agent: @agent, session_id: "test-session", pre_session_mass: pre_mass)

  tool.execute(action: "delete", id: tiny.id.to_s)
  result = tool.execute(action: "complete", summary: "Minor cleanup")

  assert_equal "refinement_complete", result[:type]
  assert tiny.reload.discarded?
end
```

- [ ] **Rollback restores deleted memories**

```ruby
test "rollback undiscards deleted memories" do
  @agent.memories.create!(content: "Important" * 20, memory_type: :core)

  tool = tool_with_circuit_breaker
  m = @agent.memories.kept.core.first

  tool.execute(action: "delete", id: m.id.to_s)
  assert m.reload.discarded?

  tool.execute(action: "complete", summary: "Over-deleted")

  assert_not m.reload.discarded?
end
```

- [ ] **Rollback restores updated memories to original content**

```ruby
test "rollback restores updated memory content" do
  @agent.memories.create!(content: "Original content here" * 10, memory_type: :core)

  tool = tool_with_circuit_breaker
  m = @agent.memories.kept.core.first

  tool.execute(action: "update", id: m.id.to_s, content: "X")
  tool.execute(action: "complete", summary: "Over-compressed")

  assert_equal "Original content here" * 10, m.reload.content
end
```

- [ ] **Rollback reverses consolidations**

```ruby
test "rollback reverses consolidations" do
  m1 = @agent.memories.create!(content: "A" * 200, memory_type: :core)
  m2 = @agent.memories.create!(content: "B" * 200, memory_type: :core)

  tool = tool_with_circuit_breaker
  tool.execute(action: "consolidate", ids: "#{m1.id},#{m2.id}", content: "AB")
  tool.execute(action: "complete", summary: "Over-consolidated")

  assert_not m1.reload.discarded?
  assert_not m2.reload.discarded?
  merged = @agent.memories.find_by(content: "AB")
  assert merged.discarded?
end
```

- [ ] **Rollback reverses protect actions**

```ruby
test "rollback reverses protect actions" do
  m = @agent.memories.create!(content: "A" * 200, memory_type: :core)
  m2 = @agent.memories.create!(content: "B" * 200, memory_type: :core)

  tool = tool_with_circuit_breaker
  tool.execute(action: "protect", id: m.id.to_s)
  tool.execute(action: "delete", id: m2.id.to_s)
  tool.execute(action: "complete", summary: "Over-deleted")

  assert_not m.reload.constitutional?
  assert_not m2.reload.discarded?
end
```

- [ ] **Rollback creates audit log and journal memory**

```ruby
test "rollback creates audit log and journal memory" do
  @agent.memories.create!(content: "A" * 400, memory_type: :core)

  tool = tool_with_circuit_breaker
  m = @agent.memories.kept.core.first

  tool.execute(action: "delete", id: m.id.to_s)
  tool.execute(action: "complete", summary: "Deleted too much")

  rollback_log = AuditLog.find_by(action: "memory_refinement_rollback")
  assert rollback_log
  assert_equal @agent.effective_refinement_threshold, rollback_log.data["threshold"]
  assert @agent.memories.journal.where("content LIKE ?", "%rolled back%").exists?
end
```

- [ ] **Combined integration test: consolidate + update + delete in one session, then rollback**

```ruby
test "rollback reverses mixed mutations in a single session" do
  m1 = @agent.memories.create!(content: "Memory one " * 20, memory_type: :core)
  m2 = @agent.memories.create!(content: "Memory two " * 20, memory_type: :core)
  m3 = @agent.memories.create!(content: "Memory three " * 20, memory_type: :core)
  m4 = @agent.memories.create!(content: "Memory four " * 20, memory_type: :core)

  tool = tool_with_circuit_breaker

  tool.execute(action: "consolidate", ids: "#{m1.id},#{m2.id}", content: "Combined")
  tool.execute(action: "update", id: m3.id.to_s, content: "Shortened")
  tool.execute(action: "delete", id: m4.id.to_s)
  result = tool.execute(action: "complete", summary: "Big cleanup")

  assert_equal "refinement_rolled_back", result[:type]

  assert_not m1.reload.discarded?, "consolidated source should be restored"
  assert_not m2.reload.discarded?, "consolidated source should be restored"
  assert_equal "Memory three " * 20, m3.reload.content, "updated memory should be restored"
  assert_not m4.reload.discarded?, "deleted memory should be restored"

  merged = @agent.memories.find_by(content: "Combined")
  assert merged.discarded?, "consolidated target should be discarded"
end
```

- [ ] **Circuit breaker skipped when no pre_session_mass**

```ruby
test "complete succeeds without pre_session_mass (backward compatibility)" do
  tool = RefinementTool.new(agent: @agent)
  result = tool.execute(action: "complete", summary: "No gate")

  assert_equal "refinement_complete", result[:type]
end
```

- [ ] **Session ID included in audit logs**

```ruby
test "session_id is included in all refinement audit logs" do
  m = @agent.memories.create!(content: "Test", memory_type: :core)
  tool = RefinementTool.new(agent: @agent, session_id: "sid-123", pre_session_mass: 1000)

  tool.execute(action: "update", id: m.id.to_s, content: "Updated")
  log = AuditLog.find_by(action: "memory_refinement_update")
  assert_equal "sid-123", log.data["session_id"]
end
```

### SelfAuthoringTool Tests (`/test/tools/self_authoring_tool_test.rb`)

- [ ] **View refinement_threshold returns default when unset**

```ruby
test "view refinement_threshold returns default when unset" do
  @agent.update!(refinement_threshold: nil)
  result = @tool.execute(action: "view", field: "refinement_threshold")

  assert_equal "config", result[:type]
  assert_equal Agent::DEFAULT_REFINEMENT_THRESHOLD, result[:value]
  assert_equal true, result[:is_default]
end
```

- [ ] **View refinement_threshold returns custom value when set**

```ruby
test "view refinement_threshold returns custom value when set" do
  @agent.update!(refinement_threshold: 0.90)
  result = @tool.execute(action: "view", field: "refinement_threshold")

  assert_equal 0.90, result[:value]
  assert_equal false, result[:is_default]
end
```

- [ ] **Update refinement_threshold coerces string to float**

```ruby
test "update refinement_threshold coerces to float" do
  result = @tool.execute(action: "update", field: "refinement_threshold", value: "0.85")

  assert_equal "config", result[:type]
  assert_equal 0.85, @agent.reload.refinement_threshold
end
```

- [ ] **Update refinement_threshold validates range**

```ruby
test "update refinement_threshold rejects invalid values" do
  result = @tool.execute(action: "update", field: "refinement_threshold", value: "1.5")

  assert_equal "error", result[:type]
end
```

### Agent Model Tests (`/test/models/agent_test.rb`)

- [ ] **effective_refinement_threshold falls back to default**

```ruby
test "effective_refinement_threshold returns default when nil" do
  @agent.update!(refinement_threshold: nil)
  assert_equal Agent::DEFAULT_REFINEMENT_THRESHOLD, @agent.effective_refinement_threshold
end

test "effective_refinement_threshold returns custom value when set" do
  @agent.update!(refinement_threshold: 0.90)
  assert_equal 0.90, @agent.effective_refinement_threshold
end
```

- [ ] **Validation rejects out-of-range values**

```ruby
test "refinement_threshold validates range" do
  @agent.refinement_threshold = 0
  assert_not @agent.valid?

  @agent.refinement_threshold = 1.5
  assert_not @agent.valid?

  @agent.refinement_threshold = 0.75
  assert @agent.valid?

  @agent.refinement_threshold = nil
  assert @agent.valid?
end
```

## Edge Cases and Error Handling

1. **No pre_session_mass (backward compatibility)**: If `pre_session_mass` is `nil` or zero, `circuit_breaker_tripped?` returns `false`. Existing callers that don't pass the new arguments continue to work.

2. **Empty core memories at session start**: If `pre_session_mass` is 0, the circuit breaker is skipped.

3. **Session with only protect/search actions**: Token mass stays the same or increases. The circuit breaker won't trigger.

4. **Partial rollback failure**: The `ActiveRecord::Base.transaction` wrapper in `rollback_session!` guarantees atomicity. If any mutation reversal, audit log creation, or journal write fails, the entire rollback is aborted. A partially-rolled-back session would be worse than a fully-committed one.

5. **Consolidated memory's `prevent_constitutional_discard` during rollback**: Protect rollback runs first (reverse chronological order), removing the constitutional flag before the consolidation rollback discards the merged memory.

6. **`last_refinement_at` updated even on rollback**: Prevents the next sweep from immediately re-triggering refinement. The agent gets a journal entry explaining what happened and can adjust their threshold.

7. **Race conditions**: Each session has a unique `session_id` so rollbacks are isolated.

## Files Changed Summary

| File | Change |
|------|--------|
| `db/migrate/XXXXXX_add_refinement_threshold_to_agents.rb` | New migration: add `float` column |
| `app/models/agent.rb` | Add constant, validation, `effective_refinement_threshold` method |
| `app/models/agent_memory.rb` | Add `session_id:` keyword to `audit_refinement` |
| `app/models/audit_log.rb` | Add `for_refinement_session` scope |
| `app/tools/refinement_tool.rb` | Accept session context, include `session_id` in audits, circuit breaker + decomposed rollback in transaction |
| `app/tools/self_authoring_tool.rb` | Add `refinement_threshold` to FIELDS, `FIELD_COERCIONS` map, update `default_for` |
| `app/jobs/memory_refinement_job.rb` | Generate `session_id`, pass `token_usage` directly as `pre_session_mass` |
| `test/tools/refinement_tool_test.rb` | Circuit breaker, rollback, and integration tests with shared helper |
| `test/tools/self_authoring_tool_test.rb` | View/update threshold tests |
| `test/models/agent_test.rb` | Threshold validation and default tests |

## External Dependencies

None. All required infrastructure already exists in the codebase.
