# Memory Reflection Job - Implementation Specification

**Plan ID:** 251227-03a
**Status:** Draft - Pending Review
**Date:** December 27, 2025
**Depends On:** 251227-01c (Agent Memory Feature - implemented)

## Summary

A daily background job that allows agents to reflect on their recent journal entries and decide which should be promoted to permanent core memories.

The job:
1. Runs daily (scheduled via solid_queue recurring task)
2. Finds agents with journal memories younger than 7 days
3. For each agent, presents their core memories + recent journal entries (numbered)
4. Asks the agent which journal entries (by number) should be promoted to core
5. Promotes selected entries by changing their `memory_type` from journal to core

**Key principle:** The agent has full autonomy over its own memory. It selects which entries to promote (often none), and the job simply executes that decision.

**Total new code: ~150 lines**

---

## 1. Job Scheduling Approach

### Scheduling Strategy: Daily Recurring Job

Use solid_queue's recurring task feature to run daily:

**File:** `config/recurring.yml`

```yaml
memory_reflection:
  class: MemoryReflectionJob
  schedule: every day at 3am
  queue: default
```

This runs at a quiet time (3am) to avoid impacting user-facing operations.

### Alternative Considered: Per-Agent Scheduling

```ruby
# Schedule reflection 7 days after memory creation
after_create_commit :schedule_reflection, if: :journal?
```

**Rejected because:**
- Would create many small jobs
- Harder to reason about timing
- Daily batch is simpler and sufficient

---

## 2. Agent Selection

### Finding Agents with Recent Journal Entries

Only process agents that actually have something to reflect on:

```ruby
def agents_with_recent_journal
  Agent.joins(:memories)
       .merge(AgentMemory.active_journal)
       .distinct
end
```

This uses the existing `active_journal` scope which filters to journal entries within `JOURNAL_WINDOW` (1 week).

### Why 7 Days?

- Matches the `JOURNAL_WINDOW` constant in AgentMemory
- Journal entries older than 7 days auto-expire from prompts anyway
- Gives agents time to accumulate observations before reflecting
- Short enough that memories are still fresh and relevant

---

## 3. Reflection Prompt

The agent reviews its own memories and decides what's worth keeping permanently:

```ruby
REFLECTION_PROMPT = <<~PROMPT
  You are reflecting on your recent experiences and observations.

  Below are your permanent core memories (your identity and key learnings) followed by
  your recent journal entries (numbered, temporary observations from the past week).

  Review your journal entries and decide which, if any, should be promoted to permanent
  core memories. Consider:

  - Does this represent a lasting insight about yourself, users, or your role?
  - Is this a pattern you've observed that will remain relevant?
  - Does this capture something fundamental about how you should operate?
  - Would losing this memory make you less effective long-term?

  Most journal entries should NOT become core memories - they're meant to fade.
  Only promote entries that represent genuine, lasting insights. It is completely
  normal and expected to promote nothing.

  ## Your Core Memories (permanent)
  %{core_memories}

  ## Recent Journal Entries (will fade after 1 week)
  %{journal_entries}

  ---

  Respond ONLY with valid JSON. List the numbers of journal entries to promote:

  {"promote": [1, 3]}

  If nothing should be promoted (most common case):
  {"promote": []}
PROMPT
```

### Key Design Decisions

1. **Agent reflects on its own memories** - Full autonomy over its own memory management
2. **Selection, not rewriting** - Agent picks entries by number; the original content is preserved
3. **Promotion = type change** - Selected journals become core by updating `memory_type`
4. **Conservative by default** - Prompt emphasizes most entries should fade; doing nothing is normal

---

## 4. Model Selection

Use the agent's own model for reflection:

```ruby
def reflect_for_agent(agent)
  llm = RubyLLM.chat(
    model: agent.model_id,
    provider: :openrouter,
    assume_model_exists: true
  )
  # ...
end
```

### Why Use Agent's Model?

- Maintains agent's "voice" and perspective
- More capable models can make better judgments about their own memories
- Agents with cheaper models keep their reflection costs low
- Respects the model choice the user made for each agent

### Alternative: Always Use Haiku

Could use a fast cheap model like the conversation consolidation job does.

**Trade-off:** Cheaper but loses agent personality. The agent's model knows best what that agent values.

---

## 5. Job Implementation

**File:** `app/jobs/memory_reflection_job.rb`

```ruby
class MemoryReflectionJob < ApplicationJob
  queue_as :default

  retry_on RubyLLM::RateLimitError, wait: :polynomially_longer, attempts: 5
  retry_on RubyLLM::ServerError, wait: :polynomially_longer, attempts: 3

  def perform
    agents_with_recent_journal.find_each do |agent|
      reflect_for_agent(agent)
    rescue => e
      Rails.logger.error "Memory reflection failed for agent #{agent.id}: #{e.message}"
      # Continue with other agents
    end
  end

  private

  def agents_with_recent_journal
    Agent.joins(:memories)
         .merge(AgentMemory.active_journal)
         .distinct
  end

  def reflect_for_agent(agent)
    core_memories = agent.memories.core.pluck(:content)
    journal_entries = agent.memories.active_journal.order(:created_at)

    return if journal_entries.empty?

    prompt = format(REFLECTION_PROMPT,
      core_memories: format_core_memories(core_memories),
      journal_entries: format_journal_entries(journal_entries)
    )

    llm = RubyLLM.chat(
      model: agent.model_id,
      provider: :openrouter,
      assume_model_exists: true
    )

    response = llm.ask(prompt)
    indices_to_promote = parse_response(response)

    promote_memories(journal_entries, indices_to_promote)
  end

  def format_core_memories(memories)
    return "None yet - you're still forming your identity." if memories.empty?
    memories.map.with_index(1) { |m, i| "#{i}. #{m}" }.join("\n")
  end

  def format_journal_entries(entries)
    entries.map.with_index(1) do |memory, i|
      "#{i}. [#{memory.created_at.strftime('%Y-%m-%d')}] #{memory.content}"
    end.join("\n")
  end

  def parse_response(response)
    json = JSON.parse(response.content)
    Array(json["promote"]).map(&:to_i).reject(&:zero?)
  rescue JSON::ParserError => e
    Rails.logger.warn "Failed to parse reflection response: #{e.message}"
    []
  end

  def promote_memories(journal_entries, indices)
    entries_array = journal_entries.to_a

    promoted_count = 0
    indices.each do |index|
      memory = entries_array[index - 1]  # Convert 1-based to 0-based
      next unless memory

      memory.update!(memory_type: :core)
      promoted_count += 1
    end

    if promoted_count > 0
      Rails.logger.info "Agent #{entries_array.first.agent_id} promoted #{promoted_count} journal entries to core memories"
    end
  end

  REFLECTION_PROMPT = <<~PROMPT
    You are reflecting on your recent experiences and observations.

    Below are your permanent core memories (your identity and key learnings) followed by
    your recent journal entries (numbered, temporary observations from the past week).

    Review your journal entries and decide which, if any, should be promoted to permanent
    core memories. Consider:

    - Does this represent a lasting insight about yourself, users, or your role?
    - Is this a pattern you've observed that will remain relevant?
    - Does this capture something fundamental about how you should operate?
    - Would losing this memory make you less effective long-term?

    Most journal entries should NOT become core memories - they're meant to fade.
    Only promote entries that represent genuine, lasting insights. It is completely
    normal and expected to promote nothing.

    ## Your Core Memories (permanent)
    %{core_memories}

    ## Recent Journal Entries (will fade after 1 week)
    %{journal_entries}

    ---

    Respond ONLY with valid JSON. List the numbers of journal entries to promote:

    {"promote": [1, 3]}

    If nothing should be promoted (most common case):
    {"promote": []}
  PROMPT
end
```

---

## 6. Recurring Task Configuration

**File:** `config/recurring.yml` (create if doesn't exist)

```yaml
# Solid Queue recurring tasks
# See: https://github.com/rails/solid_queue#recurring-tasks

memory_reflection:
  class: MemoryReflectionJob
  schedule: every day at 3am
  queue: default
```

If the file doesn't exist, also update `config/application.rb` or the solid_queue initializer to load it.

---

## 7. Implementation Checklist

### Job
- [ ] Create `app/jobs/memory_reflection_job.rb`
- [ ] Create/update `config/recurring.yml`
- [ ] Verify solid_queue recurring tasks are configured

### Testing
- [ ] Unit tests for agent selection
- [ ] Unit tests for prompt formatting
- [ ] Unit tests for response parsing
- [ ] Integration test with mocked LLM

---

## 8. Testing Strategy

**File:** `test/jobs/memory_reflection_job_test.rb`

```ruby
require "test_helper"

class MemoryReflectionJobTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:assistant)
    @agent.memories.destroy_all

    # Create some journal entries
    @journal1 = @agent.memories.create!(content: "User prefers concise answers", memory_type: :journal)
    @journal2 = @agent.memories.create!(content: "Discussed project deadline of Jan 15", memory_type: :journal)
    @journal3 = @agent.memories.create!(content: "I work best when I ask clarifying questions", memory_type: :journal)
  end

  test "skips agents without recent journal entries" do
    @agent.memories.journal.destroy_all

    # Should complete without calling LLM
    MemoryReflectionJob.perform_now

    assert_equal 0, @agent.memories.core.count
  end

  test "skips agents with only expired journal entries" do
    @agent.memories.journal.update_all(created_at: 2.weeks.ago)

    MemoryReflectionJob.perform_now

    assert_equal 0, @agent.memories.core.count
  end

  test "promotes selected journal entries to core" do
    # Agent selects entries 1 and 3
    response = { "promote" => [1, 3] }

    mock_llm_response(response.to_json) do
      MemoryReflectionJob.perform_now
    end

    @journal1.reload
    @journal2.reload
    @journal3.reload

    assert @journal1.core?, "Entry 1 should be promoted to core"
    assert @journal2.journal?, "Entry 2 should remain journal"
    assert @journal3.core?, "Entry 3 should be promoted to core"

    # Total memory count unchanged - we updated, not created
    assert_equal 3, @agent.memories.count
    assert_equal 2, @agent.memories.core.count
  end

  test "handles empty promotion list - agent chooses nothing" do
    response = { "promote" => [] }

    mock_llm_response(response.to_json) do
      MemoryReflectionJob.perform_now
    end

    # All should remain as journal
    assert_equal 0, @agent.memories.core.count
    assert_equal 3, @agent.memories.journal.count
  end

  test "handles malformed JSON gracefully" do
    mock_llm_response("This is not valid JSON") do
      MemoryReflectionJob.perform_now
    end

    # Should not raise, should not promote anything
    assert_equal 0, @agent.memories.core.count
  end

  test "ignores invalid indices" do
    # Index 99 doesn't exist
    response = { "promote" => [1, 99] }

    mock_llm_response(response.to_json) do
      MemoryReflectionJob.perform_now
    end

    # Only entry 1 should be promoted
    assert_equal 1, @agent.memories.core.count
    @journal1.reload
    assert @journal1.core?
  end

  test "continues processing other agents if one fails" do
    agent2 = agents(:researcher)
    agent2.memories.create!(content: "Some observation", memory_type: :journal)

    call_count = 0
    mock = lambda do |*args|
      call_count += 1
      raise "Simulated error" if call_count == 1
      OpenStruct.new(content: '{"promote": []}')
    end

    RubyLLM.stub :chat, ->(**opts) { OpenStruct.new(ask: mock) } do
      MemoryReflectionJob.perform_now
    end

    # Should have attempted both agents
    assert_equal 2, call_count
  end

  test "includes core memories and numbered journal entries in prompt" do
    @agent.memories.create!(content: "I am a helpful assistant", memory_type: :core)

    prompt_received = nil
    mock = lambda do |prompt|
      prompt_received = prompt
      OpenStruct.new(content: '{"promote": []}')
    end

    RubyLLM.stub :chat, ->(**opts) { OpenStruct.new(ask: mock) } do
      MemoryReflectionJob.perform_now
    end

    assert_includes prompt_received, "I am a helpful assistant"
    assert_includes prompt_received, "1. ["  # Numbered entries
    assert_includes prompt_received, "User prefers concise answers"
  end

  private

  def mock_llm_response(content)
    response = OpenStruct.new(content: content)
    mock_chat = OpenStruct.new(ask: ->(_prompt) { response })

    RubyLLM.stub :chat, ->(**opts) { mock_chat } do
      yield
    end
  end
end
```

---

## 9. Code Summary

| Component | Lines | File |
|-----------|-------|------|
| MemoryReflectionJob | 100 | `app/jobs/memory_reflection_job.rb` |
| Recurring config | 5 | `config/recurring.yml` |
| Tests | ~80 | `test/jobs/memory_reflection_job_test.rb` |
| **Total** | **~185** | |

---

## 10. Security Considerations

- **No user data mixing**: Each agent only sees its own memories
- **Rate limiting implicit**: Job runs once daily, processes each agent once
- **LLM API key security**: Uses existing RubyLLM configuration
- **Content limits**: AgentMemory model validates 10k char max

---

## 11. Cost Considerations

- Uses agent's own model (varies by agent)
- Typical reflection: ~2k tokens input, ~100 tokens output
- Only runs for agents with active journal entries
- Daily frequency keeps costs predictable
- Estimated: $0.01-0.10 per agent per day depending on model

---

## 12. Open Questions for Review

1. **Time of day**: 3am seems reasonable - is there a better time?

2. **Batching**: For accounts with many agents, should we batch/throttle to avoid rate limits?

### Resolved Decisions

- **Agent's own model**: Yes, always. Agent autonomy and self-responsibility.
- **Promotion mechanism**: Update `memory_type` from journal to core (no duplication).
- **Agent responsibility**: Agent selects by index; no programmatic extras.
- **Opt-out**: Agent can simply return `{"promote": []}` - autonomy built in.

---

## 13. Relationship to Other Memory Jobs

### ConsolidateConversationJob (251227-02a)
- **Trigger**: 6 hours after conversation goes idle
- **Input**: Conversation messages
- **Output**: Creates both journal AND core memories from conversation
- **Perspective**: External observer extracting memories

### MemoryReflectionJob (this spec)
- **Trigger**: Daily scheduled job
- **Input**: Agent's existing journal + core memories
- **Output**: Promotes journal entries to core memories
- **Perspective**: Agent self-reflecting on its experiences

These jobs are complementary:
1. Conversation consolidation creates initial journal entries
2. Reflection allows the agent to decide what's worth keeping permanently

---

## 14. Future Enhancements (Out of Scope)

- Admin UI showing reflection history
- Manual "reflect now" button per agent
- Configurable reflection frequency per agent
- Metrics on promotion rates
- Agent can suggest edits to existing core memories
