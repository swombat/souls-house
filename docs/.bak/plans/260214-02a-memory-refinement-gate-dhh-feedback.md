# DHH Review: Gate 4 -- Memory Refinement Session Circuit Breaker

**Spec reviewed**: `/docs/plans/260214-02a-memory-refinement-gate.md`
**Date**: 2026-02-14

---

## Overall Assessment

This is a well-structured spec that stays true to the Rails way. It leverages existing infrastructure (soft-delete, audit trail, token counting) rather than inventing new abstractions. The rollback logic lives in the tool where it is consumed, the threshold lives on the model where it belongs, and the migration is minimal. The spec is almost ready for implementation.

There are a few issues worth fixing before code is written. The biggest one is the `rollback_session!` method -- it is 40+ lines of case-switching that belongs on a model or at minimum should be broken into named private methods. The SelfAuthoringTool type coercion, while necessary, introduces a pattern that will rot as more non-string fields are added. And the test suite, while thorough, has some structural issues around test isolation and redundancy.

None of these are showstoppers. This is tighten-and-ship territory, not back-to-the-drawing-board.

---

## Critical Issues

### 1. `rollback_session!` is too big and lives at the wrong level of abstraction

The method is a 40-line procedural blob doing four different things: querying audit logs, reversing each mutation type, creating a rollback audit log, and creating a journal memory. That is too much for one method, and the case statement iterating over audit log types is doing work that arguably belongs closer to the data.

Two options, both acceptable:

**Option A (preferred): Break it up into named private methods in RefinementTool**

```ruby
def rollback_session!
  reverse_session_mutations!
  record_rollback_audit!
  record_rollback_journal!
  @agent.update!(last_refinement_at: Time.current)
end

def reverse_session_mutations!
  session_audit_logs.each { |log| reverse_mutation(log) }
end

def reverse_mutation(log)
  case log.action
  when "memory_refinement_delete"
    AgentMemory.with_discarded.find_by(id: log.auditable_id)&.undiscard!
  when "memory_refinement_update"
    AgentMemory.find_by(id: log.auditable_id)
      &.update!(content: log.data["before"]) if log.data["before"]
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

def session_audit_logs
  AuditLog.where(
    "action LIKE 'memory_refinement_%' AND data->>'session_id' = ?",
    @session_id
  ).order(created_at: :desc)
end
```

This reads like prose. Each method does one thing and has a clear name.

**Option B: Move rollback to AgentMemory or Agent as a class method**

```ruby
# In Agent
def rollback_refinement_session!(session_id)
  # ...
end
```

I would not go this route. The rollback is tightly coupled to the RefinementTool's session concept and audit log structure. Putting it on Agent would force the model to know about audit log data shapes and refinement-specific conventions. The tool is the right home -- it just needs to be decomposed.

### 2. The raw SQL JSON query needs a scope

This line appears in `rollback_session!`:

```ruby
AuditLog.where(
  "action LIKE 'memory_refinement_%' AND data->>'session_id' = ?",
  @session_id
)
```

Raw SQL with JSON operators scattered in a tool is a code smell. Define a scope on AuditLog:

```ruby
# In AuditLog
scope :for_refinement_session, ->(session_id) {
  where("action LIKE 'memory_refinement_%' AND data->>'session_id' = ?", session_id)
}
```

Then the tool reads:

```ruby
AuditLog.for_refinement_session(@session_id).order(created_at: :desc)
```

This is The Rails Way. Scopes on models, queries out of tools.

---

## Improvements Needed

### 3. SelfAuthoringTool type coercion is a smell

The spec introduces this:

```ruby
coerced = field == "refinement_threshold" ? value.to_f : value
```

This works for one field, but it is the seed of a future `case` statement. When the next numeric field is added, someone will add another condition, and then another, and you will have a type coercion switch statement growing in the middle of `update_field`.

Better: define a coercion map at the class level.

```ruby
FIELD_COERCIONS = {
  "refinement_threshold" => :to_f
}.freeze

def update_field(field, value)
  return validation_error("value required for update") if value.blank?

  coerced = FIELD_COERCIONS[field] ? value.public_send(FIELD_COERCIONS[field]) : value

  if @current_agent.update(field => coerced)
    # ...
```

This is declarative. It scales. It documents the exception rather than burying it in a ternary.

### 4. `pre_session_mass` aliasing in the job is noise

The spec says:

```ruby
session_id = SecureRandom.uuid
pre_session_mass = token_usage

tool = RefinementTool.new(agent: agent, session_id: session_id, pre_session_mass: pre_session_mass)
```

`pre_session_mass` is just `token_usage` with a different name. Two names for the same value in the same method is not clarity, it is clutter. Either rename `token_usage` to `pre_session_mass` at the point it is calculated, or just pass `token_usage` directly:

```ruby
session_id = SecureRandom.uuid
tool = RefinementTool.new(agent: agent, session_id: session_id, pre_session_mass: token_usage)
```

The keyword argument name already documents what it means. No alias needed.

### 5. `circuit_breaker_tripped?` does not need the `to_f` call

```ruby
ratio = new_mass.to_f / @pre_session_mass
```

Both `new_mass` and `@pre_session_mass` are already integers coming from `core_token_usage`, which returns `.to_i`. The `.to_f` on `new_mass` is fine for the division, but the guard clause `@pre_session_mass > 0` already prevents division by zero. This is minor -- not wrong, just worth noting that the `to_f` is only needed for correct float division, which is its actual purpose. Leave it.

### 6. The `protect` rollback assumption needs documentation in code, not just in prose

The spec explains in a "Note on `rollback_session!`" paragraph that protect actions are reversed because the entire session is suspect. This is a non-obvious design decision. The code should make this self-evident, either through a method name or a brief comment. This is one of the rare cases where a comment earns its place:

```ruby
when "memory_refinement_protect"
  # Entire session is suspect -- revert newly-granted constitutional flags too
  AgentMemory.find_by(id: log.auditable_id)&.update!(constitutional: false)
```

Or better, extract to a method whose name explains the intent:

```ruby
def reverse_protect_from_suspect_session(log)
  AgentMemory.find_by(id: log.auditable_id)&.update!(constitutional: false)
end
```

### 7. Wrap rollback mutations in a transaction

The `rollback_session!` method performs multiple database writes (undiscards, content restores, new audit log, journal memory). If any of these fail partway through, you have a partially-rolled-back session, which is worse than a fully-committed one. Wrap the entire rollback in a transaction:

```ruby
def rollback_session!
  ActiveRecord::Base.transaction do
    reverse_session_mutations!
    record_rollback_audit!
    record_rollback_journal!
    @agent.update!(last_refinement_at: Time.current)
  end
end
```

This is basic data integrity. The consolidation action already uses a transaction for the same reason.

---

## What Works Well

**Leveraging existing infrastructure.** The spec does not invent a new audit system, a new soft-delete mechanism, or a new token counter. It wires together what is already there. This is the kind of restraint that keeps a codebase clean.

**Fat model placement of the threshold.** The constant, validation, and accessor method all live on `Agent`. The job and tool consume them. This is textbook.

**Session ID over timestamp ranges.** Option A from the requirements doc was the right call. A UUID is deterministic and unambiguous. Timestamp ranges invite off-by-one bugs and timezone headaches.

**Backward compatibility.** The `session_id: nil` defaults and the `return false unless @pre_session_mass` guard mean existing callers and tests keep working without modification. This is thoughtful.

**The test suite.** Nine tests for the circuit breaker covering the happy path, sad path, each rollback type, backward compatibility, and audit log verification. The SelfAuthoringTool tests cover view/update/validation. The Agent model tests cover the threshold accessor and validation. This is good coverage.

**No new gems, no new tables, one column.** The migration footprint is minimal. This is the kind of change that should be easy to review in a PR.

---

## Test Critique

### Tests are solid but have a few structural issues

**Redundant setup in rollback tests.** Tests like "rollback undiscards deleted memories" and "rollback creates audit log and journal memory" repeat the same setup pattern: create memory, snapshot mass, create tool, delete, force threshold to 1.0, complete. Extract a helper:

```ruby
def tool_with_circuit_breaker(agent, threshold: 1.0)
  pre_mass = agent.core_token_usage
  agent.update!(refinement_threshold: threshold)
  RefinementTool.new(agent: agent, session_id: "test-#{SecureRandom.hex(4)}", pre_session_mass: pre_mass)
end
```

**The "circuit breaker triggers on excessive compression" test creates memories with `"A" * 400`.** This works but is fragile -- it depends on the token estimation formula (`length / 4.0`). If that formula changes, the test breaks for non-obvious reasons. Consider using a helper that creates memories with a known token count, or at least add a comment explaining the math.

**Missing test: rollback when `consolidate` + `update` + `delete` happen in the same session.** The spec tests each rollback type individually, which is correct for unit coverage, but a single integration-style test that exercises all three mutation types in one session and verifies the rollback undoes all of them would catch ordering bugs in the reverse-chronological processing.

**The "complete succeeds without pre_session_mass" test creates no memories.** This means the `complete_action` creates a journal memory and updates `last_refinement_at` on an agent with no core memories. This is technically valid backward-compatibility testing, but consider whether a tool with no session context should even be creating journal entries. The existing behavior does this, so it is inherited rather than introduced, but worth noting.

---

## Summary of Recommended Changes

1. **Break `rollback_session!` into named private methods** -- `reverse_session_mutations!`, `reverse_mutation`, `reverse_consolidation`, `record_rollback_audit!`, `record_rollback_journal!`
2. **Wrap rollback in a transaction**
3. **Add `for_refinement_session` scope to AuditLog** -- get the raw SQL out of the tool
4. **Use a `FIELD_COERCIONS` map in SelfAuthoringTool** instead of an inline conditional
5. **Drop the `pre_session_mass` alias** in the job -- pass `token_usage` directly
6. **Add one integration test** that exercises multiple mutation types in a single session rollback
7. Minor: consider extracting a test helper for the repeated circuit-breaker setup pattern

These are all refinements, not redesigns. The architecture is sound. Ship it after these adjustments.
