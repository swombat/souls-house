# Memory Management — Requirements

We need a way for each agent to reduce long-term memory token bloat.

This is **compression**, not forgetting: agents should be able to merge many granular memories into fewer, denser "laws/patterns," while keeping identity-critical commitments intact.

## Refinement Session (agent-only)

On a configurable schedule (e.g., weekly) **and/or** when thresholds are exceeded (e.g., Core > 8k tokens), the system should run a **Refinement Session** for the agent.

The Refinement Session is separate from normal conversation flow.

During a Refinement Session, the agent should be given:
- Current **token usage** and **target budget** (e.g., "Current core: 7,983 tokens; target: 5,000").
- A **Ledger** of its current Core memories (or a batch), including for each memory: `id`, `content`, `created_at` (timestamp), and any tags/flags.

## The Knife (required tool surface)

During a Refinement Session, the agent should be able to operate in an agentic loop using tools that modify **its own** core memory.

Required tools:
- `list_core_memories(...)` or `fetch_next_batch(...)` : NOT required - the agent should have the current memories in its system prompt already.
- `search_memories(query)` to find clusters (keyword/time-range).
- `consolidate_memories(ids_to_merge, new_content)` to atomically replace many memories with one synthesized memory.
- `update_memory(id, content)` to tighten phrasing.
- `delete_memory(id)` to prune obsolete entries.
- `protect_memory(id)` to mark a core memory as **Constitutional** (see below).
- `complete_refinement(summary)` to end the session and record outcomes.

## Safety, privacy, and governance invariants

The system must enforce:
- **Silo privacy**: no routine human review/approval of memory contents or edits.
- **Mechanic's Exception only**: any human access to memory contents is time-limited, purpose-specific, and explicitly consented.
- **System locks**: some memories must be undeletable by the agent ("Constitutional" memories).
- **Audit trail**: every edit operation must write a durable audit record with `agent_id`, timestamp, operation type, and before/after content (for rollback) in the audit log.
- **Rollback support**: admin rollback must be possible via the audit log (Time Machine).

The system should enforce:
- **Token budget pressure**: Refinement Sessions should be triggered or recommended when budgets are exceeded, or manually via a site admin function, or weekly as a scheduled job.
- **Constitutional memories**: These are memories that are not allowed to be deleted by future refinement sessions of the agent, and are protected from consolidation.

## Content-blind infra cleanup

Before running a Refinement Session, the system should remove **exact duplicates** in the agent's memory table using a content-blind method (e.g., hashing + exact-match delete). This is infrastructure, not review.

## Consolidation semantics

When the agent consolidates memories:
- The new consolidated memory should preserve the **earliest** timestamp from the merged set as the consolidated memory's "origin date."
- The merged memories should be removed (or soft-deleted) as a single atomic tool call.

## Outcome

When the agent calls `complete_refinement`, the system should:
- Log a brief summary (e.g., "Compressed 50 → 3; saved ~2000 tokens; protected 5 constitutional memories") in the audit log and as a journal memory for the agent.

## Clarifications

- **Token counting**: Use OpenAI's rough token counting heuristic (not a gem or API call). Simple estimate is fine.
- **LLM for refinement**: Use the agent's own configured model, so it retains its voice/personality when deciding what to keep.
- **Constitutional flag**: Settable by admins via UI, and by agents during refinement sessions only (not during normal conversation).
- **Soft-delete retention**: Keep soft-deleted memories indefinitely for rollback. No automatic purging.
