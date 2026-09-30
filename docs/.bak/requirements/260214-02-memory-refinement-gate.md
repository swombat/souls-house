# Gate 4: Memory Refinement Session Circuit Breaker

**Date**: 2026-02-14
**Status**: Draft
**Complexity**: Low-medium
**Origin**: Agent request in chat `oewGBe` -- agents call this "Gate 4 / Mass Latch"

## Summary

Add a post-session circuit breaker to the memory refinement process ("the Knife"). After a refinement session completes, compare total core memory token mass before vs after. If more than a configurable threshold was cut in a single session, automatically roll back all changes using the existing audit trail.

This prevents runaway compression from silently eroding agent identity in a single weekly run.

## Why This Makes Sense

- Memory refinement runs weekly on a cron with no human in the loop
- The refinement tool is an agentic loop -- the agent makes multiple consolidate/delete/update decisions per session
- Each individual decision may be reasonable, but the cumulative effect can be excessive (observed: 7.9k tokens down to 1.1k across 4 passes)
- The system already has a consent gate (agents must opt in). This adds a *result* gate
- Token mass is a crude proxy for meaning, but it's cheap to measure and catches the worst case: catastrophic over-compression

## Current State

The pieces are already in place:

- **Token counting**: `AgentMemory` estimates tokens as `(content.length / 4.0).ceil`
- **`core_token_usage`**: `Agent#core_token_usage` sums all active core memory tokens
- **Soft-delete**: Memories use the Discard gem (`discarded_at`), not hard delete
- **Audit trail**: Every refinement mutation (consolidate, update, delete) creates an `AuditLog` entry with `before`/`after` content
- **Session boundary**: The `complete` action in `RefinementTool` marks the end of a session

## Approach: Post-Session Check with Audit-Based Rollback

### Why not dry-run?

The refinement tool is an agentic loop -- the agent reads current state, makes a decision, mutates, then reads the new state to decide the next action. A dry-run mode would require simulating all mutations without persisting them, which means either a complex in-memory state layer or transaction wrapping across multiple LLM round-trips. Too much complexity for the benefit.

### Why post-session rollback works

Since every mutation is already logged in `AuditLog` with full before/after content, and deletes are soft-deletes, rollback is straightforward:

1. **Deleted memories**: Un-discard them (clear `discarded_at`)
2. **Updated memories**: Restore `before` content from audit log
3. **Consolidated memories**: Restore original memories from audit log, discard the merged one

### Implementation

**1. Record pre-session mass in `MemoryRefinementJob#refine_agent`**

Before building the refinement prompt, snapshot:
```ruby
old_mass = agent.core_token_usage
```

Pass this value through so it's available after the session completes.

**2. Check post-session mass in `RefinementTool#complete_action`**

After the refinement session finishes (agent calls `complete`), compare:
```ruby
new_mass = agent.core_token_usage
ratio = new_mass.to_f / old_mass

if old_mass > 0 && ratio < threshold
  rollback_refinement_session!(agent, session_audit_logs)
  # Return message to agent explaining the rollback
end
```

**3. Rollback method**

Find all `AuditLog` entries from this refinement session and reverse them:

- `memory_refinement_delete` -- find the discarded memory, un-discard it
- `memory_refinement_update` -- restore the `before` content
- `memory_refinement_consolidate` -- restore original memories from audit data, discard the new merged memory

**4. Configuration**

- Default threshold: 0.75 (allow up to 25% reduction per session)
- Store as a constant on `MemoryRefinementJob` or in agent settings
- The agents asked for 10% (0.90 ratio) but that's likely too conservative for early runs where memories may be genuinely bloated. Start at 25%, tighten later based on observed data.

### Session Tracking

To identify which audit logs belong to a single refinement session, either:

- **Option A**: Add a `session_id` field to audit log entries created during refinement (a UUID generated at session start)
- **Option B**: Use timestamp range -- all `memory_refinement_*` audit logs for this agent between session start and `complete` call

Option A is cleaner. Generate the session ID in the job, pass it through to the tool.

## Key Files

| File | Change |
|------|--------|
| `app/jobs/memory_refinement_job.rb` | Snapshot pre-session mass, generate session ID |
| `app/tools/refinement_tool.rb` | Pass session ID to audit logs, add post-session check in `complete_action` |
| `app/models/audit_log.rb` | No schema change needed if using `data` JSON field for session ID |
| `app/models/agent_memory.rb` | Add `undiscard` / rollback helper if needed |

## What This Doesn't Solve

- **Quality vs quantity**: An agent could consolidate 5 memories into 1 that's 95% of the original token count but loses important nuance. Token mass won't catch that. This is a known limitation -- the gate catches catastrophic compression, not subtle meaning loss.
- **Multi-pass accumulation**: If the agent stays under 25% each week but consistently compresses, memories still erode over time. This is by design -- gradual refinement is the point. The gate only catches single-session blowouts.

## Threshold Discussion

The agents asked for 10% (`new_mass / old_mass < 0.90 -> abort`). This is probably too tight:

- A healthy first refinement on bloated memories could easily cut 30-40%
- Consolidating 3 verbose duplicates into 1 tight memory is good hygiene, even if it drops 20%
- The Constitutional protection flag already shields identity-critical memories from any modification

Starting at 25% gives room for genuine cleanup while still catching the "7.9k to 1.1k" scenario. Can be tightened per-agent later if needed.

## Clarifications

1. **Notification on rollback**: When the circuit breaker triggers, the agent should be told why via a journal memory, and a `memory_refinement_rollback` audit log entry should be created for admin traceability.

2. **Threshold is per-agent with a global default**: Store the threshold per-agent (e.g. in agent settings or a column), falling back to a global default of 0.75. The identity tool should be extended so agents can edit their own threshold -- e.g. Chris could set his to 0.90 if he wants tighter protection.

3. **Session ID in JSON data field**: Store the `session_id` inside the existing `data` JSON column on audit logs. No migration needed for audit_logs -- just pass it through consistently.
