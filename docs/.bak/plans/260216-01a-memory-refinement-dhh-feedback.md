# DHH Review: Memory Refinement Improvements (260216-01a)

**Spec reviewed:** `/docs/plans/260216-01a-memory-refinement.md`
**Requirements:** `/docs/requirements/260216-01-memory-refinement.md`

---

## Overall Assessment

This is a well-structured, pragmatic spec that solves a real production problem -- an LLM carpet-bombing an agent's memories -- with proportionate, layered defenses. The code is idiomatic Rails. No service objects. No gratuitous abstractions. The job stays a job, the tool stays a tool, the model stays the model. The changes are additive and surgical: swap two prompt methods, add a counter and a check to `execute`, add one column and wire it through. That is the right instinct.

There are a few places where the spec introduces unnecessary friction or inconsistency with patterns already established in the codebase. I will call those out. But the overall shape is sound. This spec would survive a Rails core review with minor revisions.

---

## Critical Issues

### 1. Inconsistent fallback pattern for `refinement_prompt`

The spec explicitly says "No `effective_refinement_prompt` accessor is needed" and instead inlines the fallback in `build_refinement_prompt`:

```ruby
agent_instructions = agent.refinement_prompt.presence || Agent::DEFAULT_REFINEMENT_PROMPT
```

But `Agent` already has `effective_refinement_threshold` and `effective_summary_prompt` doing exactly this job. The codebase has established a convention: nullable column + `effective_*` method + default constant. Breaking that convention to save one method is false economy. The next person reading the Agent model will find `effective_refinement_threshold`, `effective_summary_prompt`, but no `effective_refinement_prompt` and wonder why.

The `SelfAuthoringTool#default_for` already duplicates this fallback logic. With an `effective_refinement_prompt` method on Agent, the tool can just call the model method instead of reimplementing the default logic.

**Fix:** Add `effective_refinement_prompt` to `Agent`, following the existing pattern:

```ruby
def effective_refinement_prompt
  refinement_prompt.presence || DEFAULT_REFINEMENT_PROMPT
end
```

Then in `build_refinement_prompt`:

```ruby
agent_instructions = agent.effective_refinement_prompt
```

And in `SelfAuthoringTool#default_for`:

```ruby
when "refinement_prompt"
  Agent::DEFAULT_REFINEMENT_PROMPT
```

This keeps the default_for method as the "what is the factory default" lookup, and the `effective_*` method as the "what does this agent actually use" lookup. Two distinct questions, two distinct places.

### 2. `protect` should not be classified as non-mutating for circuit breaker purposes

The spec says: "`protect` is not a mutating action for cap/retention purposes. It adds safety, not risk."

I disagree with the reasoning but agree with the conclusion. The cap exists to stop the LLM from going on a rampage. Protecting memories is not a rampage. Counting it toward the cap would penalize the LLM for doing something safe. Keep it as-is -- but acknowledge in the spec that `protect` IS a mutation (it changes `constitutional` from false to true, it creates an audit log) that is deliberately excluded from the cap because it is always a safe operation. The current framing elides the distinction between "does not mutate state" (false) and "does not pose risk" (true).

This is a documentation nit, not a code change.

---

## Improvements Needed

### 3. The `DEFAULT_REFINEMENT_PROMPT` is too long once `.squish`ed

```ruby
DEFAULT_REFINEMENT_PROMPT = <<~PROMPT.squish.freeze
  De-duplicate only. A memory is redundant ONLY if another memory already carries
  the same specific moment, quote, or insight. Tighten phrasing within individual
  memories if possible. When uncertain, do nothing. Bias toward completing with
  zero operations.
PROMPT
```

`.squish` collapses this into a single line. That is fine for a short sentence. This is five sentences. When an agent views this via the self-authoring tool, or when it appears in the refinement prompt, it will be one dense wall of text. Use `.strip.freeze` instead and let the heredoc's natural line breaks breathe:

```ruby
DEFAULT_REFINEMENT_PROMPT = <<~PROMPT.strip.freeze
  De-duplicate only. A memory is redundant ONLY if another memory already carries
  the same specific moment, quote, or insight. Tighten phrasing within individual
  memories if possible. When uncertain, do nothing. Bias toward completing with
  zero operations.
PROMPT
```

### 4. The refinement prompt's "Hard Rules" section repeats the default refinement prompt

The `build_refinement_prompt` has a "Hard Rules" section that says:

> "A memory is redundant ONLY if another memory already carries the same specific moment, quote, or insight. Near-duplicates with different emotional texture are NOT duplicates."

Then the "Your Refinement Style" section injects `DEFAULT_REFINEMENT_PROMPT` which says:

> "A memory is redundant ONLY if another memory already carries the same specific moment, quote, or insight."

Nearly identical text, separated by a heading. When an agent has no custom `refinement_prompt`, the LLM reads the same instruction twice. DRY applies to prompts too. Either remove the redundancy definition from the Hard Rules section (relying on the agent instructions to carry it), or make the default refinement prompt shorter and complementary to the hard rules.

I would go with: keep the definition in Hard Rules (since those are non-negotiable and should not depend on the agent's custom prompt), and make the default refinement prompt simply:

```ruby
DEFAULT_REFINEMENT_PROMPT = <<~PROMPT.strip.freeze
  When uncertain, do nothing. Bias toward completing with zero operations.
PROMPT
```

The hard rules already cover what counts as a duplicate. The default agent style just adds the conservative bias. If an agent writes a custom refinement prompt, they get the hard rules AND their own style -- no redundancy either way.

### 5. Redundant `[ usage - budget, 0 ].max` in refinement prompt

In `build_refinement_prompt`:

```ruby
- #{usage > budget ? "Over budget by: #{[ usage - budget, 0 ].max} tokens" : "Within budget"}
```

If `usage > budget` is true, then `usage - budget` is already positive. The `[..., 0].max` is dead code. The consent prompt gets this right (no `.max` guard). Make them consistent:

```ruby
- #{usage > budget ? "Over budget by: #{usage - budget} tokens" : "Within budget"}
```

### 6. Test stubs are getting unwieldy

The test helper `stub_consent_and_refinement` creates an anonymous mock with `define_singleton_method`. The new tests in the spec propose a similar `mock_factory` pattern inlined in the test body. This is starting to smell. There are now two patterns: the helper method and the inline mock.

The existing `stub_consent_and_refinement` helper is the right call. Extend it rather than duplicating the pattern inline. The "consent prompt does not mention compression" test builds its own mock factory from scratch when it could use a variant of the helper with a `capture_consent_prompt` option:

```ruby
def stub_consent_and_refinement(consent_answer,
                                 on_refinement: nil,
                                 capture_refinement_prompt: nil,
                                 capture_consent_prompt: nil)
```

Then the test becomes:

```ruby
test "consent prompt does not mention compression" do
  @agent.memories.create!(content: "Test memory", memory_type: :core)

  consent_prompt = nil

  stub_consent_and_refinement("NO", capture_consent_prompt: ->(p) { consent_prompt = p }) do
    MemoryRefinementJob.perform_now(@agent.id)
  end

  assert_includes consent_prompt, "de-duplicate"
  assert_not_includes consent_prompt, "removing obsolete"
end
```

One pattern, one place to maintain. The test reads better too.

### 7. `memory_context` is missing from the refinement prompt

The consent prompt includes `agent.memory_context` (giving the LLM access to its own memories in natural form). The refinement prompt does not. This is intentional -- the refinement prompt has its own ledger format with IDs and metadata. But the current `build_refinement_prompt` in production also does not include it, so this is consistent. Just worth noting: the consent prompt and refinement prompt have different identity contexts (consent gets `memory_context`, refinement does not). If this is deliberate, it is fine. If it is an oversight, the spec should address it.

### 8. Migration is fine but test file locations are not specified

The spec shows test code inline but does not name the test files. The existing tests live at:
- `/test/tools/refinement_tool_test.rb`
- `/test/jobs/memory_refinement_job_test.rb`

The spec should explicitly say "add to `/test/tools/refinement_tool_test.rb`" and "add to `/test/jobs/memory_refinement_job_test.rb`" for each block. An implementer should not have to guess.

---

## What Works Well

**The three-part structure is clean.** Part A (prompt), Part B (enforcement), Part C (per-agent customization) are independent, can be reviewed separately, and could even be deployed in stages if needed. Each part has a clear "before" and "after."

**The hard cap is enforced in both prompt AND code.** Belt and suspenders. The LLM is told "10 max" and the code refuses after 10. This is the right way to work with LLMs -- never trust the prompt alone.

**The per-operation circuit breaker is elegant.** Checking retention after every mutation and immediately rolling back if the threshold is breached is much better than only checking at `complete`. The implementation reuses the existing `rollback_session!` and `@terminated` machinery cleanly. No new concepts introduced.

**`protect` being excluded from the mutation cap is correct.** An agent should never be penalized for marking something as important. Good design instinct.

**The `MUTATING_ACTIONS` constant is a nice touch.** It makes the classification explicit and testable. `ACTIONS` for all actions, `MUTATING_ACTIONS` for the dangerous subset. Clear.

**The full `refinement_tool.rb` listing in Part B is helpful.** Showing the complete file means the implementer can diff against the current file and see exactly what changed. No ambiguity.

**The testing plan is thorough and targeted.** Hard cap enforcement, failed operations not counting, non-mutating operations not counting, mid-session circuit breaker rollback, post-rollback termination. These cover the meaningful edge cases.

**The migration is properly minimal.** One nullable text column, no backfill, no downtime. Exactly right.

---

## Minor Nits

- The `build_refinement_prompt` method is getting long (~30 lines of template). Consider whether the ledger formatting could be extracted to `format_memory_ledger(memories)` -- the same pattern `MemoryReflectionJob` uses with `format_journal_entries`. Not critical but would improve readability.

- The spec mentions `agent.memory_context` in the consent prompt but the refinement prompt intentionally omits it. A one-line comment in the code explaining why would prevent a future contributor from "fixing" this apparent inconsistency.

---

## Summary of Recommended Changes

| # | Change | Priority |
|---|--------|----------|
| 1 | Add `effective_refinement_prompt` to Agent following existing convention | High |
| 3 | Use `.strip.freeze` instead of `.squish.freeze` for the default prompt | Medium |
| 4 | Remove redundant "what is a duplicate" text from either Hard Rules or default prompt | Medium |
| 5 | Remove dead `[..., 0].max` guard | Low |
| 6 | Extend `stub_consent_and_refinement` instead of creating inline mocks | Medium |
| 8 | Name target test files explicitly in the spec | Low |

None of these are blockers. The spec can be implemented as-is and refined afterward. But addressing items 1 and 4 before implementation will produce cleaner code on the first pass.
