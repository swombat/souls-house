# Gate 4: Memory Refinement Session Circuit Breaker

**Date**: 2026-02-14
**Status**: Ready for implementation
**Complexity**: Low-medium
**Requirements**: `/docs/requirements/260214-02-memory-refinement-gate.md`

## Executive Summary

Add a post-session circuit breaker to the memory refinement process. After a refinement session completes, compare total core memory token mass before vs after. If more than a configurable threshold was cut in a single session, automatically roll back all changes using the existing audit trail. This prevents runaway compression from silently eroding agent identity in a single weekly run.

The implementation touches four files plus a migration and tests. No new gems or npm packages required. Every piece of infrastructure needed (soft-delete, audit trail, token counting) already exists.

## Architecture Overview

```
MemoryRefinementJob#refine_agent
  |
  |-- snapshot pre_session_mass = agent.core_token_usage
  |-- generate session_id = SecureRandom.uuid
  |-- pass both to RefinementTool.new(agent:, session_id:, pre_session_mass:)
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

No default in the database. The default lives in the model (convention over configuration). A `nil` value means "use the global default."

### Step 2: Agent model -- add threshold accessor with fallback

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

The constant is on the model because that is where the business logic lives (fat models). The validation ensures agents cannot set nonsensical values (e.g., 0 or negative). A `nil` value is valid and means "use the default."

### Step 3: SelfAuthoringTool -- add `refinement_threshold` to FIELDS

- [ ] Add `refinement_threshold` to `FIELDS` array and update `default_for` and `description`

In `/app/tools/self_authoring_tool.rb`:

```ruby
FIELDS = %w[
  name
  system_prompt
  reflection_prompt
  memory_reflection_prompt
  refinement_threshold
].freeze

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

Update `update_field` to handle the type conversion -- `refinement_threshold` arrives as a string from the LLM but needs to be stored as a float:

```ruby
def update_field(field, value)
  if value.blank?
    return validation_error("value required for update")
  end

  coerced = field == "refinement_threshold" ? value.to_f : value

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

### Step 4: RefinementTool -- accept session_id and pre_session_mass, add circuit breaker

- [ ] Update `initialize` to accept `session_id:` and `pre_session_mass:`
- [ ] Include `session_id` in all audit log `data` hashes
- [ ] Add circuit breaker check in `complete_action`
- [ ] Add `rollback_session!` private method

In `/app/tools/refinement_tool.rb`:

**Constructor change:**

```ruby
def initialize(agent:, session_id: nil, pre_session_mass: nil)
  super()
  @agent = agent
  @session_id = session_id
  @pre_session_mass = pre_session_mass
  @stats = { consolidated: 0, updated: 0, deleted: 0, protected: 0 }
end
```

**Include `session_id` in every audit log's data hash.** Three places need updating:

1. `consolidate_action` -- the `AuditLog.create!` call already builds a `data:` hash. Add `session_id: @session_id`:

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

2. `update_action` and `delete_action` call `memory.audit_refinement(...)` which creates the audit log inside `AgentMemory`. We need to pass `session_id` through. Update `AgentMemory#audit_refinement` to accept an optional `session_id:` keyword:

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

Then in `RefinementTool`:

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

**Private methods for circuit breaker:**

```ruby
def circuit_breaker_tripped?
  return false unless @pre_session_mass && @pre_session_mass > 0

  new_mass = @agent.core_token_usage
  ratio = new_mass.to_f / @pre_session_mass
  ratio < @agent.effective_refinement_threshold
end

def rollback_session!
  session_logs = AuditLog.where(
    "action LIKE 'memory_refinement_%' AND data->>'session_id' = ?",
    @session_id
  ).order(created_at: :desc)

  session_logs.each do |log|
    case log.action
    when "memory_refinement_delete"
      memory = AgentMemory.with_discarded.find_by(id: log.auditable_id)
      memory&.undiscard!
    when "memory_refinement_update"
      memory = AgentMemory.find_by(id: log.auditable_id)
      memory&.update!(content: log.data["before"]) if log.data["before"]
    when "memory_refinement_consolidate"
      new_memory = AgentMemory.find_by(id: log.data.dig("result", "id"))
      new_memory&.discard!

      log.data["merged"]&.each do |original|
        old_memory = AgentMemory.with_discarded.find_by(id: original["id"])
        old_memory&.undiscard!
      end
    when "memory_refinement_protect"
      memory = AgentMemory.find_by(id: log.auditable_id)
      memory&.update!(constitutional: false) if memory
    end
  end

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

  @agent.memories.create!(
    content: "Refinement session rolled back: compression exceeded " \
             "#{(@agent.effective_refinement_threshold * 100).to_i}% retention threshold. " \
             "All changes from this session have been reversed to protect memory integrity.",
    memory_type: :journal
  )

  @agent.update!(last_refinement_at: Time.current)
end
```

Note on `rollback_session!`:
- Processes audit logs in reverse chronological order so dependent operations unwind cleanly.
- Uses `with_discarded` (Discard scope) to find soft-deleted records.
- Protect actions are also reversed -- if the circuit breaker fires, the entire session is suspect, so newly-granted constitutional flags from that session should also be reverted.
- The `last_refinement_at` is still updated even on rollback. This prevents the agent from immediately re-triggering refinement on the next sweep. The next attempt will happen on the normal weekly schedule.

### Step 5: MemoryRefinementJob -- snapshot mass and generate session_id

- [ ] Update `refine_agent` to capture pre-session mass and generate session_id

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
  pre_session_mass = token_usage

  tool = RefinementTool.new(agent: agent, session_id: session_id, pre_session_mass: pre_session_mass)
  prompt = build_refinement_prompt(agent, core_memories, token_usage, budget)

  chat_for(agent).with_tool(tool).ask(prompt)

  Rails.logger.info "[Refinement] Agent #{agent.id} (#{agent.name}) complete: #{tool.stats.inspect}"
end
```

The only change is: generate `session_id` and `pre_session_mass` before creating the tool, then pass them through. The `token_usage` variable already exists and represents the pre-session mass, so we alias it for clarity.

### Step 6: AgentMemory -- update `audit_refinement` signature

- [ ] Add `session_id:` keyword argument to `audit_refinement`

Already shown in Step 4. The full updated method in `/app/models/agent_memory.rb`:

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

The `session_id: nil` default ensures backward compatibility if `audit_refinement` is ever called outside a refinement session context.

## Testing Strategy

### RefinementTool Tests (`/test/tools/refinement_tool_test.rb`)

- [ ] **Circuit breaker triggers on excessive compression**

```ruby
test "complete rolls back when compression exceeds threshold" do
  m1 = @agent.memories.create!(content: "A" * 400, memory_type: :core)
  m2 = @agent.memories.create!(content: "B" * 400, memory_type: :core)

  pre_mass = @agent.core_token_usage
  tool = RefinementTool.new(agent: @agent, session_id: "test-session", pre_session_mass: pre_mass)

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
  m = @agent.memories.create!(content: "Important", memory_type: :core)
  pre_mass = @agent.core_token_usage
  tool = RefinementTool.new(agent: @agent, session_id: "test-rollback", pre_session_mass: pre_mass)

  tool.execute(action: "delete", id: m.id.to_s)
  assert m.reload.discarded?

  # Force a rollback by having pre_session_mass equal the single memory
  # and threshold at 1.0 (any reduction triggers)
  @agent.update!(refinement_threshold: 1.0)
  tool.execute(action: "complete", summary: "Over-deleted")

  assert_not m.reload.discarded?
end
```

- [ ] **Rollback restores updated memories to original content**

```ruby
test "rollback restores updated memory content" do
  m = @agent.memories.create!(content: "Original content here", memory_type: :core)
  pre_mass = @agent.core_token_usage
  tool = RefinementTool.new(agent: @agent, session_id: "test-rollback-update", pre_session_mass: pre_mass)

  tool.execute(action: "update", id: m.id.to_s, content: "X")
  @agent.update!(refinement_threshold: 1.0)
  tool.execute(action: "complete", summary: "Over-compressed")

  assert_equal "Original content here", m.reload.content
end
```

- [ ] **Rollback reverses consolidations**

```ruby
test "rollback reverses consolidations" do
  m1 = @agent.memories.create!(content: "A" * 200, memory_type: :core)
  m2 = @agent.memories.create!(content: "B" * 200, memory_type: :core)
  pre_mass = @agent.core_token_usage
  tool = RefinementTool.new(agent: @agent, session_id: "test-rollback-consolidate", pre_session_mass: pre_mass)

  tool.execute(action: "consolidate", ids: "#{m1.id},#{m2.id}", content: "AB")
  @agent.update!(refinement_threshold: 1.0)
  tool.execute(action: "complete", summary: "Over-consolidated")

  assert_not m1.reload.discarded?
  assert_not m2.reload.discarded?
  merged = @agent.memories.find_by(content: "AB")
  assert merged.discarded?
end
```

- [ ] **Rollback creates audit log and journal memory**

```ruby
test "rollback creates audit log and journal memory" do
  m = @agent.memories.create!(content: "A" * 400, memory_type: :core)
  pre_mass = @agent.core_token_usage
  tool = RefinementTool.new(agent: @agent, session_id: "test-audit", pre_session_mass: pre_mass)

  tool.execute(action: "delete", id: m.id.to_s)
  @agent.update!(refinement_threshold: 1.0)
  tool.execute(action: "complete", summary: "Deleted too much")

  assert AuditLog.exists?(action: "memory_refinement_rollback")
  rollback_log = AuditLog.find_by(action: "memory_refinement_rollback")
  assert_equal "test-audit", rollback_log.data["session_id"]
  assert @agent.memories.journal.where("content LIKE ?", "%rolled back%").exists?
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

- [ ] **Rollback reverses protect actions**

```ruby
test "rollback reverses protect actions" do
  m = @agent.memories.create!(content: "A" * 400, memory_type: :core)
  m2 = @agent.memories.create!(content: "B" * 400, memory_type: :core)
  pre_mass = @agent.core_token_usage
  tool = RefinementTool.new(agent: @agent, session_id: "test-protect-rollback", pre_session_mass: pre_mass)

  tool.execute(action: "protect", id: m.id.to_s)
  tool.execute(action: "delete", id: m2.id.to_s)
  @agent.update!(refinement_threshold: 1.0)
  tool.execute(action: "complete", summary: "Over-deleted")

  assert_not m.reload.constitutional?
  assert_not m2.reload.discarded?
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

### Agent Model Tests

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

1. **No pre_session_mass (backward compatibility)**: If `pre_session_mass` is `nil` or zero, `circuit_breaker_tripped?` returns `false`. This ensures existing callers that don't pass the new arguments continue to work.

2. **Empty core memories at session start**: If `pre_session_mass` is 0 (agent has no core memories), the circuit breaker is skipped. You can't compress nothing.

3. **Session with only protect/search actions**: If the agent only searches or protects memories, token mass stays the same or increases. The circuit breaker won't trigger. The `complete` path works normally.

4. **Consolidated memory's `prevent_constitutional_discard` during rollback**: When rolling back a consolidation, the newly-created merged memory is discarded. Since it was just created during this session, it shouldn't be constitutional. If somehow it is (agent protected it and then completed), the protect rollback runs first (reverse chronological order), removing the constitutional flag before the consolidation rollback discards it.

5. **Partial audit log matches**: The `session_id` query uses an exact match on the JSON `data` field. Only audit logs from this specific session are touched.

6. **`last_refinement_at` updated even on rollback**: This is intentional. Without it, the next sweep would immediately re-trigger refinement for this agent, potentially causing a loop. The agent gets a journal entry explaining what happened and can adjust their threshold for next time.

7. **Race conditions**: The refinement job processes agents sequentially within a single job. Concurrent runs for the same agent are not expected, but even if they occurred, each session has a unique `session_id` so rollbacks are isolated.

## Files Changed Summary

| File | Change |
|------|--------|
| `db/migrate/XXXXXX_add_refinement_threshold_to_agents.rb` | New migration: add `float` column |
| `app/models/agent.rb` | Add constant, validation, `effective_refinement_threshold` method |
| `app/models/agent_memory.rb` | Add `session_id:` keyword to `audit_refinement` |
| `app/tools/refinement_tool.rb` | Accept session context, include `session_id` in audits, circuit breaker + rollback |
| `app/tools/self_authoring_tool.rb` | Add `refinement_threshold` to FIELDS, update `default_for`, type coercion in `update_field` |
| `app/jobs/memory_refinement_job.rb` | Generate `session_id`, snapshot `pre_session_mass`, pass to tool |
| `test/tools/refinement_tool_test.rb` | Circuit breaker and rollback tests |
| `test/tools/self_authoring_tool_test.rb` | View/update threshold tests |
| `test/models/agent_test.rb` | Threshold validation and default tests |

## External Dependencies

None. All required infrastructure already exists in the codebase.
