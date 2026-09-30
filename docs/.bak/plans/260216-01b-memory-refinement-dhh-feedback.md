# DHH Review: Memory Refinement Improvements (260216-01b)

**Spec reviewed:** `/docs/plans/260216-01b-memory-refinement.md`
**Requirements:** `/docs/requirements/260216-01-memory-refinement.md`
**Previous review:** `/docs/plans/260216-01a-memory-refinement-dhh-feedback.md`

---

## Overall Assessment

This is ready for implementation. Every item from the first review was addressed, and addressed well. The spec author did not just mechanically apply the feedback -- they understood the reasoning behind each point and made changes that are better than what I suggested in some cases. The `effective_refinement_prompt` now follows the established convention. The default prompt is trimmed to two sentences. The redundancy between Hard Rules and the default prompt is eliminated. The test stubs extend the existing helper instead of duplicating inline mocks. The `memory_context` omission is documented with a clear rationale. The ledger formatting is extracted. This is clean, surgical work.

I have one genuine concern and a few minor observations. None are blockers.

---

## Previous Review Feedback: Status

| # | Feedback | Status | Notes |
|---|----------|--------|-------|
| 1 | Add `effective_refinement_prompt` | Addressed | Follows existing `effective_*` convention exactly |
| 2 | Acknowledge `protect` IS a mutation | Addressed | Behavioral summary rewritten clearly |
| 3 | Use `.strip.freeze` not `.squish.freeze` | Addressed | |
| 4 | Remove redundant duplicate definition | Addressed | Default trimmed to just conservative bias |
| 5 | Remove dead `[..., 0].max` | Addressed | |
| 6 | Extend `stub_consent_and_refinement` | Addressed | Added `capture_consent_prompt` parameter |
| 7 | Clarify `memory_context` omission | Addressed | Explicit note in Part A item 10 |
| 8 | Name target test files | Addressed | All test sections specify exact paths |
| nit | Extract ledger formatting | Addressed | `format_memory_ledger` added |

All eight items addressed. Clean sweep.

---

## One Genuine Concern

### The mid-session rollback returns the pre-rollback result, not a rollback result

Look at the `execute` flow after a successful mutation:

```ruby
result = send("#{action}_action", **params)

if MUTATING_ACTIONS.include?(action) && result[:type] != "error"
  @mutation_count += 1
  check_retention_after_mutation!
end

result
```

If `check_retention_after_mutation!` trips the circuit breaker and rolls back the entire session, `execute` still returns the original `result` -- which says `{ type: "deleted", id: 42 }`. That deletion was just reversed. The LLM receives a success response for an operation that no longer exists.

The LLM's *next* call will hit `terminated_error`, so it cannot do further damage. But the false success response is confusing for audit trail reading and could theoretically cause the LLM to emit a misleading summary before it realizes the session is dead.

The fix is simple. After the retention check, if the session was terminated, return the rollback information instead of the stale result:

```ruby
if MUTATING_ACTIONS.include?(action) && result[:type] != "error"
  @mutation_count += 1
  check_retention_after_mutation!
  return terminated_error if @terminated
end

result
```

This is a one-line addition. The LLM immediately learns the session was rolled back, on the same turn that triggered it. Cleaner semantics, no ambiguity.

---

## Minor Observations

### 1. The default prompt assertion test needs updating

The test "refinement prompt uses default when agent has no custom refinement_prompt" asserts:

```ruby
assert_includes refinement_prompt, Agent::DEFAULT_REFINEMENT_PROMPT
```

This is correct and will work with the trimmed default ("When uncertain, do nothing. Bias toward completing with zero operations."). But the previous iteration's test (in 260216-01a) asserted `"De-duplicate only"` -- which no longer appears in the default. The 01b spec correctly uses `Agent::DEFAULT_REFINEMENT_PROMPT` instead. Good. Just confirming this was intentional and correct.

### 2. The `summary_prompt` field is missing from `SelfAuthoringTool` FIELDS

This is not something introduced by this spec, but I noticed it while reading the existing code. The Agent model has `effective_summary_prompt` and `DEFAULT_SUMMARY_PROMPT`, but `summary_prompt` is not in the `SelfAuthoringTool::FIELDS` array. This means agents cannot view or edit their summary prompt via the self-authoring tool. The new `refinement_prompt` is being added correctly -- but if `summary_prompt` was intentionally excluded, it might be worth a comment explaining why. If it was an oversight, it could be fixed in this same change since the SelfAuthoringTool is already being modified. Not a blocker either way.

### 3. The changes-from-01a table is thorough and appreciated

The table at the bottom mapping each review comment to what changed is excellent practice. It makes reviewing the second iteration fast. More specs should do this.

---

## What Works Well

**The prompt rewrite is the real fix.** The hard cap and per-operation circuit breaker are necessary safety nets, but the prompt change from "compression, not forgetting" to "de-duplication, not compression" is what will actually change the LLM's behavior. Framing matters enormously with LLMs. Telling it to "merge granular memories into denser patterns" is a mandate to compress. Telling it "de-duplicate exact duplicates, doing nothing is fine" is a mandate to be conservative. The spec understands this.

**The layered defense is textbook.** Prompt framing (soft), hard cap at 10 (hard), per-operation circuit breaker (hard), defense-in-depth check at complete (safety net). Four layers, each independent, each catching different failure modes. No single point of failure.

**The `effective_refinement_prompt` method is two lines and follows convention perfectly.** No cleverness, no surprise. Anyone reading the Agent model will find `effective_refinement_threshold`, `effective_summary_prompt`, and `effective_refinement_prompt` all doing the same thing the same way. Convention over configuration at the model level.

**The default refinement prompt is the right length.** Two sentences. The Hard Rules carry the heavy lifting (what counts as a duplicate, what is protected, what the cap is). The default agent style just adds conservative bias. An agent who writes a custom refinement prompt does not need to re-state the rules -- they get them for free. This is clean separation of concerns.

**The test plan covers the right edge cases.** Hard cap enforcement, failed ops not counting, protect not counting, mid-session rollback, post-rollback termination, prompt content assertions for both consent and refinement, custom vs. default refinement prompts. The `capture_consent_prompt` extension to the existing stub helper is the right pattern.

---

## Verdict

Apply the one-line fix for the post-rollback return value. Everything else is ready to implement as written.

| Item | Priority | Action |
|------|----------|--------|
| Post-rollback return value | Medium | Add `return terminated_error if @terminated` after retention check |
| `summary_prompt` in SelfAuthoringTool | Low | Investigate whether this is an intentional omission or oversight; fix opportunistically if desired |

Ship it.
