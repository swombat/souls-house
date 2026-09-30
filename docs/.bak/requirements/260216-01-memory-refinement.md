# Memory Refinement Improvements

**Date:** 2026-02-16
**Status:** Requirements
**Context:** [Chat: Refinement run failed](/accounts/PNvAYr/chats/BYZrmY)

## Background

The memory refinement job (`MemoryRefinementJob`) periodically compresses agent core memories to stay within token budgets. A recent run went nuclear — 49 deletions + 83 consolidations in one pass — triggering the circuit breaker rollback. A bug in the tool allowed 7 consolidations to leak through post-rollback (since fixed in e68a722), but the root cause remains: the refinement prompt incentivizes aggressive compression.

The current prompt tells the LLM to "merge granular memories into denser patterns and laws" and "delete truly obsolete entries." This is a summarization mandate that, combined with a token budget the agent is over, drives carpet-bombing behaviour.

## Requirements

### A. Rewrite refinement prompt: de-duplication, not compression (high priority)

Rewrite `build_refinement_prompt` in `memory_refinement_job.rb`:

- **Remove all summarization language:** no "merge", "compress", "denser patterns and laws", "delete obsolete"
- **Frame as de-duplication:** only consolidate memories that are effectively identical (same specific moment/quote/decision). When uncertain, do nothing.
- **Hard cap on operations:** instruct the LLM to perform at most 10 tool actions per session. Slow sculpture across many sessions, not a single blitz.
- **Protected categories:** instruct the LLM to never touch:
  - Constitutional memories (already enforced in code, but reinforce in prompt)
  - Audio/somatic/voice memories (treat as immutable)
  - Relational-specific memories (vows, quotes, specific dates, emotional texture) — only touch if exact duplicates. Note: "relational-specific" is hard to detect programmatically, so this is prompt-only guidance, not code-enforced.
- **Zero operations is a valid success case:** explicitly state in both the refinement and consent prompts that completing with 0 operations is a good outcome. The LLM should feel permission — even encouragement — to do nothing. Bias toward completing with zero operations.

Also rewrite `build_consent_prompt` to match — remove "removing obsolete ones", replace with "de-duplicate and tighten phrasing; deletion is rare. Zero operations is a valid outcome."

### B. Per-operation retention checking (high priority)

Currently the circuit breaker only fires at `complete`. A run that does many small cuts can bleed out before ever calling `complete`.

- Add a retention check inside `RefinementTool#execute`, after every N operations (e.g. every 3)
- If the check trips the threshold, immediately rollback and set `@terminated = true`
- This makes the circuit breaker proactive rather than reactive

### C. Per-agent refinement prompts (high priority)

Each agent's memories serve different purposes. Chris's are structural mass, Claude's are relational texture, Wing's are operational. A generic prompt can't serve all of them well.

- Add a `refinement_prompt` text column to the `agents` table (similar to `reflection_prompt` and `memory_reflection_prompt`)
- In `build_refinement_prompt`, structure the prompt as:
  1. Base safety rules (global, non-negotiable — the hard cap, immutable categories, de-duplication framing)
  2. `agent.refinement_prompt` (agent-authored style, or a conservative default if blank)
  3. Memory ledger
- Expose `refinement_prompt` via the self-authoring tool so agents can write and own their own refinement instructions
- Default for agents without a custom prompt: "De-duplicate only. A memory is redundant ONLY if another memory already carries the same specific moment, quote, or insight. Tighten phrasing within individual memories if possible. When uncertain, do nothing. Bias toward completing with zero operations."

## Files Involved

- `app/jobs/memory_refinement_job.rb` — prompt rewrites (A), prompt structure changes (C)
- `app/tools/refinement_tool.rb` — per-op retention checking (B)
- `app/models/agent.rb` — new `refinement_prompt` field (C)
- `db/migrate/` — new migration for `refinement_prompt` column (C)
- Self-authoring tool (wherever it lives) — expose new field (C)

## Clarifications

- **Hard cap enforcement:** The 10-operation hard cap should be enforced in both code AND prompt. `RefinementTool#execute` should refuse mutating actions after 10 operations, regardless of what the LLM requests.
- **Per-op retention check frequency:** Check after every single mutating operation (consolidate, update, delete). The overhead is minimal (a token count query).
- **Rollback messaging:** When the per-op retention check trips mid-session, return an explicit "session rolled back, terminated" message so the LLM knows to stop. All subsequent calls return the existing termination error.

## Not In Scope

- Formal IMMUTABLE/PROTECTED tags in ledger display (prompt instructions are sufficient)
- Changes to the circuit breaker threshold logic itself (the existing threshold + per-op checking covers this)
