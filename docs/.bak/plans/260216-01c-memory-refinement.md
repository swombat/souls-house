# Memory Refinement Improvements

**Date:** 2026-02-16
**Spec:** 260216-01c (final)
**Status:** Ready for implementation
**Requirements:** [260216-01-memory-refinement](/docs/requirements/260216-01-memory-refinement.md)
**Previous:** [260216-01a](/docs/plans/260216-01a-memory-refinement.md) | [01a feedback](/docs/plans/260216-01a-memory-refinement-dhh-feedback.md) | [260216-01b](/docs/plans/260216-01b-memory-refinement.md) | [01b feedback](/docs/plans/260216-01b-memory-refinement-dhh-feedback.md)

## Overview

A recent refinement run carpet-bombed an agent's core memories: 49 deletions + 83 consolidations in a single pass. The root cause is a prompt that frames refinement as *compression* ("merge granular memories into denser patterns and laws", "delete truly obsolete entries"). This spec rewrites the prompt to frame refinement as *de-duplication*, adds a hard cap of 10 mutating operations enforced in code, checks the circuit breaker after every single mutating operation (not just at `complete`), and introduces per-agent refinement prompts so each agent can own its own refinement style.

Three parts, all high priority:

| Part | What | Files touched |
|------|------|---------------|
| A | Prompt rewrite (de-duplication, not compression) | `memory_refinement_job.rb` |
| B | Per-operation retention checking + hard cap | `refinement_tool.rb` |
| C | Per-agent refinement prompts | migration, `agent.rb`, `self_authoring_tool.rb`, `memory_refinement_job.rb` |

---

## Part A: Prompt Rewrite

Replace both `build_consent_prompt` and `build_refinement_prompt` in `/app/jobs/memory_refinement_job.rb`.

### `build_consent_prompt` -- full method replacement

- [ ] Replace `build_consent_prompt` in `memory_refinement_job.rb`

```ruby
def build_consent_prompt(agent, memories, usage, budget)
  <<~PROMPT
    #{agent.system_prompt}

    #{agent.memory_context}

    #{development_preamble}# Memory Refinement Request

    A scheduled memory refinement session is about to run. Before it begins, you are being asked whether you consent to this session.

    ## Current Status
    - Core memories: #{memories.size}
    - Token usage: #{usage} tokens
    - Token budget: #{budget} tokens
    - #{usage > budget ? "Over budget by: #{usage - budget} tokens" : "Within budget"}

    Memory refinement will review your core memories to de-duplicate entries and tighten phrasing. It does NOT summarize, compress, or delete memories unless they are exact duplicates. Constitutional memories are never touched. Completing with zero operations is a valid and good outcome.

    Do you want to run memory refinement now? Reply with **YES** or **NO** as the first word of your response. You may briefly explain your reasoning after.
  PROMPT
end
```

### `build_refinement_prompt` -- full method replacement

- [ ] Replace `build_refinement_prompt` in `memory_refinement_job.rb`

```ruby
def build_refinement_prompt(agent, memories, usage, budget)
  ledger = format_memory_ledger(memories)

  <<~PROMPT
    #{agent.system_prompt}

    #{development_preamble}# Memory Refinement Session

    You are reviewing your own core memories. This is de-duplication, not compression.

    ## Hard Rules (non-negotiable)
    - You may perform AT MOST 10 mutating operations (consolidate, update, delete) in this session. The system will refuse further operations after 10.
    - CONSTITUTIONAL memories cannot be deleted or consolidated.
    - Audio, somatic, and voice memories are immutable. Do not touch them.
    - Relational-specific memories (vows, quotes, specific dates, emotional texture) should only be touched if they are exact duplicates of another memory.
    - A memory is redundant ONLY if another memory already carries the same specific moment, quote, or insight. Near-duplicates with different emotional texture are NOT duplicates.
    - Completing with ZERO operations is a valid and good outcome.

    ## Your Refinement Style
    #{agent.effective_refinement_prompt}

    ## Current Status
    - Core memories: #{memories.size}
    - Token usage: #{usage} tokens
    - Token budget: #{budget} tokens
    - #{usage > budget ? "Over budget by: #{usage - budget} tokens" : "Within budget"}

    ## Your Core Memory Ledger
    #{ledger}

    Review your memories. De-duplicate exact duplicates. Tighten phrasing within individual memories if possible. When done, call complete with a brief summary. Doing nothing is fine.
  PROMPT
end

def format_memory_ledger(memories)
  memories.map { |m|
    flag = m.constitutional? ? " [CONSTITUTIONAL]" : ""
    "- ##{m.id} (#{m.created_at.strftime('%Y-%m-%d')}, ~#{m.token_estimate} tokens)#{flag}: #{m.content}"
  }.join("\n")
end
```

Key changes from the current prompt:

1. **"compression, not forgetting"** replaced with **"de-duplication, not compression"**
2. **"Merge granular memories into denser patterns and laws"** removed entirely
3. **"Delete truly obsolete entries"** removed entirely
4. **Hard cap of 10** stated explicitly in the prompt
5. **Protected categories** (audio/somatic/voice, relational-specific) called out
6. **Zero operations** framed as valid and good
7. **Agent-specific refinement style** injected between rules and ledger (Part C)
8. **Dead `[..., 0].max`** removed from the over-budget line -- if `usage > budget` is true, the difference is already positive
9. **Ledger formatting** extracted to `format_memory_ledger` for readability (mirrors `MemoryReflectionJob`'s `format_journal_entries` pattern)
10. **`memory_context` intentionally omitted** from the refinement prompt -- the ledger provides the same memories in a structured format with IDs and metadata. The consent prompt retains `memory_context` because it needs the agent to reason about its memories in natural form without IDs.

---

## Part B: Per-Operation Retention Checking + Hard Cap

All changes in `/app/tools/refinement_tool.rb`.

### Full updated `/app/tools/refinement_tool.rb`

- [ ] Add `MUTATING_ACTIONS` and `MAX_MUTATIONS` constants
- [ ] Add `@mutation_count` to `initialize`
- [ ] Rewrite `execute` with hard cap + per-op retention check + post-rollback return fix
- [ ] Add `terminated_error` and `check_retention_after_mutation!` methods

```ruby
class RefinementTool < RubyLLM::Tool

  ACTIONS = %w[search consolidate update delete protect complete].freeze
  MUTATING_ACTIONS = %w[consolidate update delete].freeze
  MAX_MUTATIONS = 10

  description "Memory refinement tool. Actions: search, consolidate, update, delete, protect, complete."

  param :action, type: :string,
        desc: "search, consolidate, update, delete, protect, or complete",
        required: true

  param :query, type: :string,
        desc: "Search query (for search action)",
        required: false

  param :ids, type: :string,
        desc: "Comma-separated memory IDs (for consolidate)",
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

  attr_reader :stats

  def initialize(agent:, session_id: nil, pre_session_mass: nil)
    super()
    @agent = agent
    @session_id = session_id
    @pre_session_mass = pre_session_mass
    @stats = { consolidated: 0, updated: 0, deleted: 0, protected: 0 }
    @mutation_count = 0
    @terminated = false
  end

  def execute(action:, **params)
    Rails.logger.info "[Refinement] Agent #{@agent.id}: #{action}"
    return terminated_error if @terminated
    return validation_error("Invalid action '#{action}'") unless ACTIONS.include?(action)

    if MUTATING_ACTIONS.include?(action) && @mutation_count >= MAX_MUTATIONS
      return {
        type: "error",
        error: "Hard cap reached: #{MAX_MUTATIONS} mutating operations performed. " \
               "Call complete to finish the session."
      }
    end

    result = send("#{action}_action", **params)

    if MUTATING_ACTIONS.include?(action) && result[:type] != "error"
      @mutation_count += 1
      check_retention_after_mutation!
      return terminated_error if @terminated
    end

    result
  end

  private

  def search_action(query: nil, **)
    return param_error("search", "query") if query.blank?

    results = @agent.memories.kept.core
                    .where("content ILIKE ?", "%#{AgentMemory.sanitize_sql_like(query)}%")
                    .order(:created_at)
                    .map(&:as_ledger_entry)

    { type: "search_results", query:, count: results.size, results: }
  end

  def consolidate_action(ids: nil, content: nil, **)
    return param_error("consolidate", "ids") if ids.blank?
    return param_error("consolidate", "content") if content.blank?

    memory_ids = ids.split(",").map(&:strip).map(&:to_i)
    return { type: "error", error: "consolidate requires at least 2 memory IDs" } if memory_ids.size < 2

    memories = @agent.memories.kept.core.where(id: memory_ids)
    return { type: "error", error: "No matching memories found" } if memories.empty?

    constitutional = memories.select(&:constitutional?)
    if constitutional.any?
      return { type: "error", error: "Cannot consolidate constitutional memories: #{constitutional.map(&:id).join(', ')}" }
    end

    earliest = memories.map(&:created_at).min

    ActiveRecord::Base.transaction do
      new_memory = @agent.memories.create!(content: content.strip, memory_type: :core, created_at: earliest)

      merged = memories.map { |m| { id: m.id, content: m.content } }
      memories.each(&:discard!)

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

      @stats[:consolidated] += memories.size
    end

    { type: "consolidated", merged_count: memory_ids.size, new_content: content }
  end

  def update_action(id: nil, content: nil, **)
    return param_error("update", "id") if id.blank?
    return param_error("update", "content") if content.blank?

    memory = @agent.memories.kept.core.find_by(id: id)
    return { type: "error", error: "Memory ##{id} not found" } unless memory

    old_content = memory.content
    memory.update!(content: content.strip)
    memory.audit_refinement("update", old_content, memory.content, session_id: @session_id)
    @stats[:updated] += 1

    { type: "updated", id: memory.id, content: memory.content }
  end

  def delete_action(id: nil, **)
    return param_error("delete", "id") if id.blank?

    memory = @agent.memories.kept.core.find_by(id: id)
    return { type: "error", error: "Memory ##{id} not found" } unless memory
    return { type: "error", error: "Cannot delete constitutional memory ##{id}" } if memory.constitutional?

    memory.audit_refinement("delete", memory.content, nil, session_id: @session_id)
    memory.discard!
    @stats[:deleted] += 1

    { type: "deleted", id: memory.id }
  end

  def protect_action(id: nil, **)
    return param_error("protect", "id") if id.blank?

    memory = @agent.memories.kept.core.find_by(id: id)
    return { type: "error", error: "Memory ##{id} not found" } unless memory

    memory.update!(constitutional: true)
    memory.audit_refinement("protect", nil, nil, session_id: @session_id)
    @stats[:protected] += 1

    { type: "protected", id: memory.id, content: memory.content }
  end

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

    @terminated = true

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

  def check_retention_after_mutation!
    return unless circuit_breaker_tripped?

    Rails.logger.warn "[Refinement] Agent #{@agent.id}: mid-session circuit breaker tripped after #{@mutation_count} operations"
    rollback_session!
  end

  def circuit_breaker_tripped?
    return false unless @pre_session_mass && @pre_session_mass > 0

    new_mass = @agent.core_token_usage
    ratio = new_mass.to_f / @pre_session_mass
    ratio < @agent.effective_refinement_threshold
  end

  def rollback_session!
    @terminated = true
    post_compression_mass = @agent.core_token_usage
    ActiveRecord::Base.transaction do
      reverse_session_mutations!
      record_rollback_audit!(post_compression_mass)
      record_rollback_journal!(post_compression_mass)
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

  def record_rollback_audit!(post_compression_mass)
    AuditLog.create!(
      action: "memory_refinement_rollback",
      auditable: @agent,
      account_id: @agent.account_id,
      data: {
        session_id: @session_id,
        pre_session_mass: @pre_session_mass,
        post_session_mass: post_compression_mass,
        threshold: @agent.effective_refinement_threshold,
        stats: @stats
      }
    )
  end

  def record_rollback_journal!(post_compression_mass)
    reduction_pct = (100 - (post_compression_mass.to_f / @pre_session_mass * 100)).round(1)
    threshold_pct = (@agent.effective_refinement_threshold * 100).to_i

    stat_labels = { deleted: "deletion", consolidated: "consolidation", updated: "update", protected: "protection" }
    parts = stat_labels.filter_map { |key, word| "#{@stats[key]} #{word.pluralize(@stats[key])}" if @stats[key] > 0 }
    stats_summary = parts.any? ? "Rolled back: #{parts.join(', ')}." : ""

    @agent.memories.create!(
      content: "Refinement session rolled back. Would have reduced core memory from " \
               "#{@pre_session_mass} to #{post_compression_mass} tokens (#{reduction_pct}% cut), " \
               "exceeding the #{threshold_pct}% retention threshold. #{stats_summary} " \
               "All changes reversed to protect memory integrity.",
      memory_type: :journal
    )
  end

  def session_audit_logs
    AuditLog.for_refinement_session(@session_id).order(created_at: :desc)
  end

  def terminated_error
    { type: "error", error: "Session terminated -- no further operations allowed" }
  end

  def validation_error(message)
    { type: "error", error: message, allowed_actions: ACTIONS }
  end

  def param_error(action, param)
    { type: "error", error: "#{param} is required for #{action}" }
  end

end
```

### Behavioral summary for Part B

1. **Hard cap**: After 10 successful mutating operations (`consolidate`, `update`, `delete`), the tool returns an error telling the LLM to call `complete`. This is enforced before dispatch, so the LLM cannot bypass it.
2. **Per-operation retention check**: After every successful mutation, `check_retention_after_mutation!` runs `circuit_breaker_tripped?`. If the threshold is breached, it calls `rollback_session!` which sets `@terminated = true`. The `execute` method then returns `terminated_error` immediately -- the LLM learns the session was rolled back on the same turn that triggered it, not on the next call.
3. **`protect` is deliberately excluded from the mutation cap.** It IS a mutation (it changes `constitutional` from false to true and creates an audit log), but it is always a safe operation -- it adds protection, not risk. Counting it toward the cap would penalize the LLM for doing something beneficial.
4. **`search` and `complete`** are not counted toward the mutation cap.
5. **Defense in depth**: The existing circuit breaker check in `complete_action` remains as a safety net.

---

## Part C: Per-Agent Refinement Prompts

### Migration

- [ ] Generate migration: `rails generate migration AddRefinementPromptToAgents refinement_prompt:text`

```ruby
class AddRefinementPromptToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :refinement_prompt, :text
  end
end
```

### Agent model changes

- [ ] Add `DEFAULT_REFINEMENT_PROMPT` constant to `Agent`
- [ ] Add `effective_refinement_prompt` method to `Agent`
- [ ] Add validation for `refinement_prompt`

In `/app/models/agent.rb`:

```ruby
DEFAULT_REFINEMENT_PROMPT = <<~PROMPT.strip.freeze
  When uncertain, do nothing. Bias toward completing with zero operations.
PROMPT
```

The default is deliberately short. The Hard Rules section of the refinement prompt already defines what counts as a duplicate, what categories are protected, and what the operation cap is. The default agent style just adds the conservative bias. When an agent writes a custom refinement prompt, they get the hard rules AND their own style -- no redundancy either way.

Add the `effective_*` accessor following the established convention (`effective_refinement_threshold`, `effective_summary_prompt`):

```ruby
def effective_refinement_prompt
  refinement_prompt.presence || DEFAULT_REFINEMENT_PROMPT
end
```

Add validation alongside the existing prompt validations:

```ruby
validates :refinement_prompt, length: { maximum: 10_000 }
```

### SelfAuthoringTool changes

- [ ] Add `refinement_prompt` to `FIELDS` in `SelfAuthoringTool`
- [ ] Add default for `refinement_prompt` in `default_for`
- [ ] Update the `description` string and `param` description

In `/app/tools/self_authoring_tool.rb`:

```ruby
FIELDS = %w[
  name
  system_prompt
  reflection_prompt
  memory_reflection_prompt
  refinement_prompt
  refinement_threshold
].freeze
```

Update description:

```ruby
description "View or update your configuration. Actions: view, update. " \
            "Fields: name, system_prompt, reflection_prompt, memory_reflection_prompt, " \
            "refinement_prompt, refinement_threshold."
```

Update param description:

```ruby
param :field, type: :string,
      desc: "name, system_prompt, reflection_prompt, memory_reflection_prompt, " \
            "refinement_prompt, or refinement_threshold",
      required: true
```

Add to `default_for`:

```ruby
def default_for(field)
  case field
  when "reflection_prompt"
    ConsolidateConversationJob::EXTRACTION_PROMPT
  when "memory_reflection_prompt"
    MemoryReflectionJob::REFLECTION_PROMPT
  when "refinement_prompt"
    Agent::DEFAULT_REFINEMENT_PROMPT
  when "refinement_threshold"
    Agent::DEFAULT_REFINEMENT_THRESHOLD
  end
end
```

### Prompt structure in `build_refinement_prompt`

Already shown in Part A. The structure is:

1. **Agent system prompt** (identity context)
2. **Hard rules** (global, non-negotiable: cap, immutable categories, de-duplication framing, redundancy definition)
3. **Agent refinement prompt** via `agent.effective_refinement_prompt` (agent-authored style, or a conservative default)
4. **Status** (memory count, token usage, budget)
5. **Memory ledger** (formatted via `format_memory_ledger`)
6. **Closing instruction** (review, de-duplicate, call complete)

### Note: `summary_prompt` not in `SelfAuthoringTool::FIELDS`

The DHH review noted that `summary_prompt` is not in the `SelfAuthoringTool::FIELDS` array despite `Agent` having `effective_summary_prompt` and `DEFAULT_SUMMARY_PROMPT`. This is out of scope for this change. It may be an oversight worth investigating separately, but adding it here would expand the scope beyond what the requirements call for.

---

## Testing Plan

All tests extend existing patterns. No new mock factories.

### New tests for `RefinementToolTest` in `/test/tools/refinement_tool_test.rb`

- [ ] Write tests for hard cap enforcement
- [ ] Write tests for per-operation retention checking

```ruby
# Hard cap tests

test "refuses mutating operations after hard cap" do
  memories = 12.times.map { |i| @agent.memories.create!(content: "Memory #{i}", memory_type: :core) }
  tool = RefinementTool.new(agent: @agent, session_id: "cap-test")

  RefinementTool::MAX_MUTATIONS.times do |i|
    result = tool.execute(action: "update", id: memories[i].id.to_s, content: "Updated #{i}")
    assert_equal "updated", result[:type]
  end

  result = tool.execute(action: "update", id: memories[10].id.to_s, content: "One too many")
  assert_equal "error", result[:type]
  assert_includes result[:error], "Hard cap"
end

test "hard cap does not count failed operations" do
  m = @agent.memories.create!(content: "Real memory", memory_type: :core)
  tool = RefinementTool.new(agent: @agent, session_id: "cap-fail-test")

  5.times { tool.execute(action: "delete", id: "999999") }

  result = tool.execute(action: "update", id: m.id.to_s, content: "Still allowed")
  assert_equal "updated", result[:type]
end

test "hard cap does not count search or protect" do
  memories = 12.times.map { |i| @agent.memories.create!(content: "Memory #{i}" * 5, memory_type: :core) }
  tool = RefinementTool.new(agent: @agent, session_id: "non-mutating-test")

  5.times { tool.execute(action: "search", query: "Memory") }
  3.times { |i| tool.execute(action: "protect", id: memories[i].id.to_s) }

  RefinementTool::MAX_MUTATIONS.times do |i|
    result = tool.execute(action: "update", id: memories[i + 3].id.to_s, content: "Updated #{i}")
    assert_equal "updated", result[:type]
  end

  result = tool.execute(action: "update", id: memories.last.id.to_s, content: "Over cap")
  assert_equal "error", result[:type]
  assert_includes result[:error], "Hard cap"
end

# Mid-session circuit breaker tests

test "mid-session circuit breaker rolls back and terminates" do
  m1 = @agent.memories.create!(content: "A" * 400, memory_type: :core)
  m2 = @agent.memories.create!(content: "B" * 400, memory_type: :core)

  tool = tool_with_circuit_breaker

  tool.execute(action: "delete", id: m1.id.to_s)
  tool.execute(action: "delete", id: m2.id.to_s)

  assert_not m1.reload.discarded?, "should be undiscarded after mid-session rollback"
  assert_not m2.reload.discarded?, "should be undiscarded after mid-session rollback"

  result = tool.execute(action: "search", query: "anything")
  assert_equal "error", result[:type]
  assert_includes result[:error], "terminated"
end

test "mid-session circuit breaker returns terminated error on triggering call" do
  m1 = @agent.memories.create!(content: "A" * 400, memory_type: :core)

  tool = tool_with_circuit_breaker

  result = tool.execute(action: "delete", id: m1.id.to_s)
  assert_equal "error", result[:type]
  assert_includes result[:error], "terminated"
end

test "all calls after mid-session rollback return terminated error" do
  m1 = @agent.memories.create!(content: "A" * 400, memory_type: :core)

  tool = tool_with_circuit_breaker
  tool.execute(action: "delete", id: m1.id.to_s)

  result = tool.execute(action: "complete", summary: "Trying to complete")
  assert_equal "error", result[:type]
  assert_includes result[:error], "terminated"
end
```

These tests use the existing `tool_with_circuit_breaker` helper already defined in the test file's private section.

### Updated tests for `MemoryRefinementJobTest` in `/test/jobs/memory_refinement_job_test.rb`

- [ ] Update prompt assertion tests to reflect new prompt text
- [ ] Extend `stub_consent_and_refinement` with `capture_consent_prompt` option

First, update the `stub_consent_and_refinement` helper to support capturing the consent prompt:

```ruby
def stub_consent_and_refinement(consent_answer, on_refinement: nil,
                                capture_refinement_prompt: nil,
                                capture_consent_prompt: nil)
  mock_factory = ->(**opts) {
    mock = Object.new
    has_tool = false
    mock.define_singleton_method(:with_tool) { |_t| has_tool = true; self }
    mock.define_singleton_method(:ask) do |prompt|
      unless has_tool
        capture_consent_prompt&.call(prompt)
        return OpenStruct.new(content: consent_answer)
      end
      on_refinement&.call
      capture_refinement_prompt&.call(prompt)
      OpenStruct.new(content: "Done")
    end
    mock
  }

  RubyLLM.stub :chat, mock_factory do
    yield
  end
end
```

Then add the tests:

```ruby
test "refinement prompt includes de-duplication framing" do
  @agent.memories.create!(content: "Test memory", memory_type: :core)

  refinement_prompt = nil

  stub_consent_and_refinement("YES", capture_refinement_prompt: ->(p) { refinement_prompt = p }) do
    MemoryRefinementJob.perform_now(@agent.id)
  end

  assert_includes refinement_prompt, "de-duplication, not compression"
  assert_includes refinement_prompt, "AT MOST 10 mutating operations"
  assert_includes refinement_prompt, "ZERO operations is a valid"
  assert_not_includes refinement_prompt, "Merge granular memories"
  assert_not_includes refinement_prompt, "denser patterns"
end

test "refinement prompt includes agent refinement_prompt when set" do
  @agent.update!(refinement_prompt: "Be extra careful with relational memories.")
  @agent.memories.create!(content: "Test memory", memory_type: :core)

  refinement_prompt = nil

  stub_consent_and_refinement("YES", capture_refinement_prompt: ->(p) { refinement_prompt = p }) do
    MemoryRefinementJob.perform_now(@agent.id)
  end

  assert_includes refinement_prompt, "Be extra careful with relational memories."
end

test "refinement prompt uses default when agent has no custom refinement_prompt" do
  @agent.memories.create!(content: "Test memory", memory_type: :core)

  refinement_prompt = nil

  stub_consent_and_refinement("YES", capture_refinement_prompt: ->(p) { refinement_prompt = p }) do
    MemoryRefinementJob.perform_now(@agent.id)
  end

  assert_includes refinement_prompt, Agent::DEFAULT_REFINEMENT_PROMPT
end

test "consent prompt does not mention compression" do
  @agent.memories.create!(content: "Test memory", memory_type: :core)

  consent_prompt = nil

  stub_consent_and_refinement("NO", capture_consent_prompt: ->(p) { consent_prompt = p }) do
    MemoryRefinementJob.perform_now(@agent.id)
  end

  assert_includes consent_prompt, "de-duplicate"
  assert_not_includes consent_prompt, "removing obsolete"
  assert_not_includes consent_prompt, "compressing"
end
```

### Agent model tests in `/test/models/agent_test.rb`

- [ ] Add `effective_refinement_prompt` tests to agent model tests

```ruby
test "effective_refinement_prompt returns custom prompt when set" do
  agent = @account.agents.create!(
    name: "Custom Refinement Agent",
    refinement_prompt: "My custom refinement instructions"
  )
  assert_equal "My custom refinement instructions", agent.effective_refinement_prompt
end

test "effective_refinement_prompt returns default when blank" do
  agent = @account.agents.create!(name: "Default Refinement Agent", refinement_prompt: nil)
  assert_equal Agent::DEFAULT_REFINEMENT_PROMPT, agent.effective_refinement_prompt

  agent.update!(refinement_prompt: "")
  assert_equal Agent::DEFAULT_REFINEMENT_PROMPT, agent.effective_refinement_prompt
end
```

### SelfAuthoringTool tests in `/test/tools/self_authoring_tool_test.rb`

- [ ] Add `refinement_prompt` field tests

```ruby
test "view refinement_prompt shows default when unset" do
  result = @tool.execute(action: "view", field: "refinement_prompt")
  assert_equal "config", result[:type]
  assert_equal Agent::DEFAULT_REFINEMENT_PROMPT, result[:value]
  assert result[:is_default]
end

test "update refinement_prompt saves custom value" do
  result = @tool.execute(action: "update", field: "refinement_prompt", value: "Custom instructions")
  assert_equal "config", result[:type]
  assert_equal "Custom instructions", @current_agent.reload.refinement_prompt
end
```

---

## Implementation Checklist

- [ ] **Part A**: Replace `build_consent_prompt` in `memory_refinement_job.rb`
- [ ] **Part A**: Replace `build_refinement_prompt` in `memory_refinement_job.rb`
- [ ] **Part A**: Add `format_memory_ledger` private method to `memory_refinement_job.rb`
- [ ] **Part B**: Add `MUTATING_ACTIONS`, `MAX_MUTATIONS` constants to `RefinementTool`
- [ ] **Part B**: Add `@mutation_count` to `RefinementTool#initialize`
- [ ] **Part B**: Rewrite `RefinementTool#execute` with hard cap + per-op retention check + post-rollback return fix
- [ ] **Part B**: Add `terminated_error` and `check_retention_after_mutation!` methods
- [ ] **Part C**: Run migration to add `refinement_prompt` column to `agents`
- [ ] **Part C**: Add `DEFAULT_REFINEMENT_PROMPT` constant, `effective_refinement_prompt` method, and validation to `Agent`
- [ ] **Part C**: Update `SelfAuthoringTool` (FIELDS, description, param desc, default_for)
- [ ] **Tests**: Add hard cap tests to `/test/tools/refinement_tool_test.rb`
- [ ] **Tests**: Add mid-session circuit breaker tests to `/test/tools/refinement_tool_test.rb`
- [ ] **Tests**: Extend `stub_consent_and_refinement` with `capture_consent_prompt` in `/test/jobs/memory_refinement_job_test.rb`
- [ ] **Tests**: Add prompt assertion tests to `/test/jobs/memory_refinement_job_test.rb`
- [ ] **Tests**: Add `effective_refinement_prompt` tests to `/test/models/agent_test.rb`
- [ ] **Tests**: Add `refinement_prompt` field tests to `/test/tools/self_authoring_tool_test.rb`
- [ ] Run `rails test` and `bin/rubocop`

## Changes from 260216-01b (DHH feedback applied)

| # | DHH Feedback | What changed |
|---|---|---|
| 1 (bug fix) | `execute` returns stale success result after mid-session rollback | Added `return terminated_error if @terminated` after `check_retention_after_mutation!` so the LLM immediately learns the session was rolled back on the same turn that triggered it |
| 2 (noted) | `summary_prompt` missing from `SelfAuthoringTool::FIELDS` | Noted as out of scope in Part C; no code change |

## Changes from 260216-01a (DHH feedback applied in 01b)

| # | DHH Feedback | What changed |
|---|---|---|
| 1 | Add `effective_refinement_prompt` following existing convention | Added `effective_refinement_prompt` to Agent; `build_refinement_prompt` calls `agent.effective_refinement_prompt` instead of inlining the fallback |
| 2 | `protect` classification should acknowledge it IS a mutation | Behavioral summary rewritten to clarify `protect` is a mutation deliberately excluded from the cap because it is always safe |
| 3 | Use `.strip.freeze` not `.squish.freeze` | `DEFAULT_REFINEMENT_PROMPT` uses `.strip.freeze` to preserve readability |
| 4 | Remove redundant "what is a duplicate" text | Hard Rules carry the redundancy definition; default prompt trimmed to just the conservative bias ("When uncertain, do nothing. Bias toward completing with zero operations.") |
| 5 | Remove dead `[..., 0].max` | Over-budget line simplified to `usage - budget` |
| 6 | Extend `stub_consent_and_refinement` instead of inline mocks | Added `capture_consent_prompt` parameter to the existing helper; consent prompt test uses it |
| 7 | `memory_context` omission is intentional | Added explicit note in Part A explaining why the refinement prompt omits `memory_context` |
| 8 | Name target test files | All test sections now specify exact file paths |
| nit | Extract ledger formatting | Added `format_memory_ledger` method mirroring `MemoryReflectionJob`'s `format_journal_entries` pattern |

## Migration / Deployment Notes

- The migration adds a nullable text column. No backfill needed -- agents without a `refinement_prompt` get `DEFAULT_REFINEMENT_PROMPT` via `effective_refinement_prompt`.
- No downtime required. The migration is additive and non-destructive.
- Deploy order does not matter: the code handles `nil` gracefully via `effective_refinement_prompt`.
- Existing agents will see no behavioral change from the migration alone. The prompt rewrite (Part A) and per-op checking (Part B) are the impactful changes.
- After deployment, agents can write their own refinement prompts via the self-authoring tool in any group chat.
