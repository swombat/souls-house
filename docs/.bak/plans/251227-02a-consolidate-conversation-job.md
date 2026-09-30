# Consolidate Conversation Job - Implementation Specification

**Plan ID:** 251227-02a
**Status:** Draft - Pending Review
**Date:** December 27, 2025
**Depends On:** 251227-01c (Agent Memory Feature - implemented)

## Summary

An hourly background job that finds group conversations idle for 6+ hours and extracts memories for each participating agent. Each agent uses its own model for extraction, maintaining agent autonomy.

The job:
1. Finds all group conversations idle for 6+ hours needing consolidation
2. For each conversation, splits messages into ~100k token chunks
3. For each agent, uses that agent's model to extract memories
4. Creates AgentMemory records (journal/core) from the extractions

**Total new code: ~290 lines**

---

## 1. Job Scheduling Approach

### Scheduling Strategy: Hourly Recurring Job

A recurring job runs every hour to find and consolidate idle conversations:

```ruby
# config/recurring.yml (Solid Queue)
consolidate_conversations:
  class: ConsolidateStaleConversationsJob
  schedule: every hour
```

The job finds conversations that:
- Are group chats (`manual_responses = true`)
- Have been idle for more than 6 hours (no messages in last 6 hours)
- Either have never been consolidated, OR have new messages since last consolidation

This approach:
- Reliable - doesn't depend on future-scheduled jobs surviving restarts
- Efficient - single query finds all conversations needing work
- Self-healing - if a consolidation fails, it'll be retried next hour
- Simple - no per-message hooks or complex scheduling

---

## 2. Token Counting & Chunking

### Token Counting

Use `OpenAI.rough_token_count` from the ruby-openai gem (already in Gemfile):

```ruby
def token_count(text)
  OpenAI.rough_token_count(text)
end
```

This is an approximation but sufficient for chunking. Exact counts aren't critical.

### Chunking Strategy

Chunk messages into groups of ~100k tokens, keeping messages intact:

```ruby
CHUNK_TARGET_TOKENS = 100_000
```

100k tokens is conservative enough to work with all major models (GPT-5.2, Claude Opus 4.5, Gemini 3 Pro, Grok 4) while being large enough to capture meaningful context.

---

## 3. Memory Extraction via LLM

### Agent Autonomy

Each agent uses its **own model** (`agent.model_id`) for memory extraction. This maintains agent autonomy - each agent is responsible for its own internal makeup, using its own capabilities to decide what to remember.

### Extraction Prompt

The prompt provides the agent's identity (system prompt) and existing core memories, letting the agent decide what's worth remembering and whether to deduplicate:

```ruby
EXTRACTION_PROMPT = <<~PROMPT
  You are reviewing a conversation you participated in to extract memories for yourself.

  Your identity:
  %{system_prompt}

  Your existing core memories:
  %{existing_memories}

  Review this conversation and decide what you want to remember:

  1. JOURNAL entries (short-term, will fade after a week):
     - Specific facts you learned about users or topics
     - Commitments or promises you made
     - Important context for ongoing work
     - Observations worth remembering temporarily

  2. CORE entries (permanent identity memories):
     - Fundamental beliefs or values you want to hold
     - Key relationships you've established
     - Important lessons you've learned
     - Defining moments or decisions

  Be selective. Only extract truly valuable memories, not routine exchanges.
  Most conversations won't need any core memories.
  You may update or refine existing memories if you've learned something new.

  Respond ONLY with valid JSON:
  {"journal": ["memory 1", "memory 2"], "core": ["memory 1"]}

  If nothing is worth remembering:
  {"journal": [], "core": []}
PROMPT
```

---

## 4. Database Design

### No New Tables Required

Uses existing `agent_memories` table from the memory spec.

### Tracking Consolidation State

Add a column to track when consolidation was last attempted, to avoid re-processing:

**Migration:** `db/migrate/[timestamp]_add_last_consolidated_at_to_chats.rb`

```ruby
class AddLastConsolidatedAtToChats < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :last_consolidated_at, :datetime
    add_column :chats, :last_consolidated_message_id, :bigint

    add_index :chats, :last_consolidated_at
  end
end
```

Design rationale:
- `last_consolidated_at` - When we last ran consolidation
- `last_consolidated_message_id` - The last message included in consolidation (so we only process new messages next time)
- No foreign key on `last_consolidated_message_id` because the message might be deleted

---

## 5. Job Implementation

### Two Jobs

1. **ConsolidateStaleConversationsJob** - Hourly recurring job that finds conversations needing consolidation
2. **ConsolidateConversationJob** - Processes a single conversation

---

### Finder Job

**File:** `app/jobs/consolidate_stale_conversations_job.rb`

```ruby
class ConsolidateStaleConversationsJob < ApplicationJob
  IDLE_THRESHOLD = 6.hours

  def perform
    stale_conversations.find_each do |chat|
      ConsolidateConversationJob.perform_later(chat)
    end
  end

  private

  def stale_conversations
    Chat
      .where(manual_responses: true)
      .where.not(id: recently_active_chat_ids)
      .where(needs_consolidation)
  end

  def recently_active_chat_ids
    Message.where("created_at > ?", IDLE_THRESHOLD.ago).select(:chat_id)
  end

  def needs_consolidation
    # Never consolidated OR has new messages since last consolidation
    <<~SQL.squish
      last_consolidated_at IS NULL
      OR last_consolidated_message_id < (
        SELECT MAX(id) FROM messages WHERE messages.chat_id = chats.id
      )
    SQL
  end
end
```

---

### Worker Job

**File:** `app/jobs/consolidate_conversation_job.rb`

```ruby
class ConsolidateConversationJob < ApplicationJob
  IDLE_THRESHOLD = 6.hours
  CHUNK_TARGET_TOKENS = 100_000

  def perform(chat)
    return unless eligible?(chat)

    messages = messages_to_consolidate(chat)
    return if messages.empty?

    chunks = chunk_messages(messages)

    chat.agents.find_each do |agent|
      extract_memories_for_agent(agent, chunks)
    end

    mark_consolidated!(chat, messages.last)
  end

  private

  def eligible?(chat)
    chat.group_chat? && !recently_active?(chat)
  end

  def recently_active?(chat)
    chat.messages.where("created_at > ?", IDLE_THRESHOLD.ago).exists?
  end

  def messages_to_consolidate(chat)
    scope = chat.messages.includes(:user, :agent).order(:created_at)

    if chat.last_consolidated_message_id
      scope = scope.where("id > ?", chat.last_consolidated_message_id)
    end

    scope.to_a
  end

  def chunk_messages(messages)
    chunks = []
    current_chunk = []
    current_tokens = 0

    messages.each do |msg|
      msg_tokens = token_count(message_text(msg))

      if current_tokens + msg_tokens > CHUNK_TARGET_TOKENS && current_chunk.any?
        chunks << current_chunk
        current_chunk = []
        current_tokens = 0
      end

      current_chunk << msg
      current_tokens += msg_tokens
    end

    chunks << current_chunk if current_chunk.any?
    chunks
  end

  def extract_memories_for_agent(agent, chunks)
    existing_core = agent.memories.core.pluck(:content)

    chunks.each do |chunk|
      extracted = call_extraction_llm(agent, chunk, existing_core)
      create_memories(agent, extracted)

      # Track new core memories for subsequent chunks
      existing_core += extracted[:core] if extracted[:core].present?
    end
  end

  def call_extraction_llm(agent, messages, existing_core)
    prompt = build_prompt(agent, existing_core)
    conversation_text = messages.map { |m| message_text(m) }.join("\n\n")

    # Agent uses its own model for extraction
    llm = RubyLLM.chat(
      model: agent.model_id,
      provider: :openrouter,
      assume_model_exists: true
    )

    response = llm.ask("#{prompt}\n\n---\n\nConversation:\n\n#{conversation_text}")
    parse_extraction_response(response)
  rescue => e
    Rails.logger.error "Memory extraction failed for agent #{agent.id}: #{e.message}"
    { journal: [], core: [] }
  end

  def build_prompt(agent, existing_core)
    format(EXTRACTION_PROMPT,
      system_prompt: agent.system_prompt.presence || "You are #{agent.name}.",
      existing_memories: format_existing_memories(existing_core)
    )
  end

  def create_memories(agent, extracted)
    extracted[:journal]&.each do |content|
      agent.memories.create(content: content.strip, memory_type: :journal)
    end

    extracted[:core]&.each do |content|
      agent.memories.create(content: content.strip, memory_type: :core)
    end
  end

  def mark_consolidated!(chat, last_message)
    chat.update_columns(
      last_consolidated_at: Time.current,
      last_consolidated_message_id: last_message.id
    )
  end

  def token_count(text)
    OpenAI.rough_token_count(text.to_s)
  end

  def message_text(msg)
    prefix = msg.agent&.name || msg.user&.full_name || msg.user&.email_address&.split("@")&.first || "User"
    "[#{prefix}]: #{msg.content}"
  end

  def format_existing_memories(memories)
    return "None yet." if memories.empty?
    memories.map { |m| "- #{m}" }.join("\n")
  end

  def parse_extraction_response(response)
    json = JSON.parse(response.content)
    {
      journal: Array(json["journal"]).map(&:to_s).reject(&:blank?),
      core: Array(json["core"]).map(&:to_s).reject(&:blank?)
    }
  rescue JSON::ParserError => e
    Rails.logger.warn "Failed to parse memory extraction response: #{e.message}"
    { journal: [], core: [] }
  end

  EXTRACTION_PROMPT = <<~PROMPT
    You are reviewing a conversation you participated in to extract memories for yourself.

    Your identity:
    %{system_prompt}

    Your existing core memories:
    %{existing_memories}

    Review this conversation and decide what you want to remember:

    1. JOURNAL entries (short-term, will fade after a week):
       - Specific facts you learned about users or topics
       - Commitments or promises you made
       - Important context for ongoing work
       - Observations worth remembering temporarily

    2. CORE entries (permanent identity memories):
       - Fundamental beliefs or values you want to hold
       - Key relationships you've established
       - Important lessons you've learned
       - Defining moments or decisions

    Be selective. Only extract truly valuable memories, not routine exchanges.
    Most conversations won't need any core memories.
    You may update or refine existing memories if you've learned something new.

    Respond ONLY with valid JSON:
    {"journal": ["memory 1", "memory 2"], "core": ["memory 1"]}

    If nothing is worth remembering:
    {"journal": [], "core": []}
  PROMPT
end
```

---

## 6. Recurring Job Configuration

**File:** `config/recurring.yml`

```yaml
# Solid Queue recurring jobs
consolidate_conversations:
  class: ConsolidateStaleConversationsJob
  schedule: every hour
```

This runs the finder job hourly, which enqueues individual consolidation jobs for each stale conversation.

---

## 7. Implementation Checklist

### Database
- [ ] Generate migration: `rails g migration AddLastConsolidatedAtToChats`
- [ ] Run migration: `rails db:migrate`

### Jobs
- [ ] Create `app/jobs/consolidate_stale_conversations_job.rb`
- [ ] Create `app/jobs/consolidate_conversation_job.rb`

### Configuration
- [ ] Add recurring job to `config/recurring.yml`

### Testing
- [ ] Finder job tests (stale conversation detection)
- [ ] Worker job tests (chunking, extraction, memory creation)
- [ ] Integration test (full consolidation flow)

---

## 8. Testing Strategy

### Finder Job Tests

**File:** `test/jobs/consolidate_stale_conversations_job_test.rb`

```ruby
require "test_helper"

class ConsolidateStaleConversationsJobTest < ActiveSupport::TestCase
  setup do
    @group_chat = chats(:group_chat)

    # Create old messages
    travel_to 7.hours.ago do
      @group_chat.messages.create!(role: "user", content: "Hello", user: users(:daniel))
    end
  end

  test "enqueues consolidation for idle group chats" do
    assert_enqueued_with(job: ConsolidateConversationJob, args: [@group_chat]) do
      ConsolidateStaleConversationsJob.perform_now
    end
  end

  test "skips recently active chats" do
    @group_chat.messages.create!(role: "user", content: "New", user: users(:daniel))

    assert_no_enqueued_jobs(only: ConsolidateConversationJob) do
      ConsolidateStaleConversationsJob.perform_now
    end
  end

  test "skips non-group chats" do
    regular_chat = chats(:regular_chat)
    travel_to 7.hours.ago do
      regular_chat.messages.create!(role: "user", content: "Old", user: users(:daniel))
    end

    # Should only enqueue for group chat, not regular chat
    ConsolidateStaleConversationsJob.perform_now
    assert_enqueued_jobs 1, only: ConsolidateConversationJob
  end

  test "skips already consolidated chats with no new messages" do
    @group_chat.update!(
      last_consolidated_at: 1.hour.ago,
      last_consolidated_message_id: @group_chat.messages.last.id
    )

    assert_no_enqueued_jobs(only: ConsolidateConversationJob) do
      ConsolidateStaleConversationsJob.perform_now
    end
  end

  test "includes previously consolidated chats with new messages" do
    @group_chat.update!(
      last_consolidated_at: 8.hours.ago,
      last_consolidated_message_id: @group_chat.messages.first.id
    )

    # Add new old message
    travel_to 7.hours.ago do
      @group_chat.messages.create!(role: "user", content: "New old", user: users(:daniel))
    end

    assert_enqueued_with(job: ConsolidateConversationJob, args: [@group_chat]) do
      ConsolidateStaleConversationsJob.perform_now
    end
  end
end
```

### Worker Job Tests

**File:** `test/jobs/consolidate_conversation_job_test.rb`

```ruby
require "test_helper"

class ConsolidateConversationJobTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:group_chat)
    @agent = @chat.agents.first

    # Create some messages older than 6 hours
    travel_to 7.hours.ago do
      @chat.messages.create!(role: "user", content: "Hello agent!", user: users(:daniel))
      @chat.messages.create!(role: "assistant", content: "Hello! I'm happy to help.", agent: @agent)
    end
  end

  test "skips non-group chats" do
    regular_chat = chats(:regular_chat)

    ConsolidateConversationJob.perform_now(regular_chat)

    assert_equal 0, @agent.memories.count
  end

  test "skips recently active conversations" do
    @chat.messages.create!(role: "user", content: "New message", user: users(:daniel))

    ConsolidateConversationJob.perform_now(@chat)

    assert_equal 0, @agent.memories.count
  end

  test "extracts memories using agent's own model" do
    extraction_response = { "journal" => ["User prefers concise responses"], "core" => [] }

    llm_mock = Minitest::Mock.new
    llm_mock.expect(:ask, OpenStruct.new(content: extraction_response.to_json), [String])

    RubyLLM.stub(:chat, ->(**args) {
      assert_equal @agent.model_id, args[:model], "Should use agent's model"
      llm_mock
    }) do
      ConsolidateConversationJob.perform_now(@chat)
    end

    assert_equal 1, @agent.memories.journal.count
  end

  test "tracks last consolidated message" do
    extraction_response = { "journal" => [], "core" => [] }
    last_message = @chat.messages.last

    stub_extraction(extraction_response) do
      ConsolidateConversationJob.perform_now(@chat)
    end

    @chat.reload
    assert_equal last_message.id, @chat.last_consolidated_message_id
    assert_not_nil @chat.last_consolidated_at
  end

  test "only processes new messages on subsequent runs" do
    stub_extraction({ "journal" => ["First"], "core" => [] }) do
      ConsolidateConversationJob.perform_now(@chat)
    end

    # Add new message (7 hours ago to be idle)
    travel_to 7.hours.ago do
      @chat.messages.create!(role: "user", content: "Another message", user: users(:daniel))
    end

    prompts_received = []
    stub_extraction({ "journal" => ["Second"], "core" => [] }, capture: prompts_received) do
      ConsolidateConversationJob.perform_now(@chat)
    end

    # Should not include old messages
    assert prompts_received.any?
    refute prompts_received.first.include?("Hello agent!"), "Should not include old messages"
    assert prompts_received.first.include?("Another message"), "Should include new message"
  end

  private

  def stub_extraction(response, capture: nil, &block)
    llm_mock = Object.new
    llm_mock.define_singleton_method(:ask) do |prompt|
      capture << prompt if capture
      OpenStruct.new(content: response.to_json)
    end

    RubyLLM.stub(:chat, ->(**_) { llm_mock }, &block)
  end
end
```

---

## 9. Code Summary

| Component | Lines | File |
|-----------|-------|------|
| Migration | 10 | `db/migrate/*_add_last_consolidated_at_to_chats.rb` |
| ConsolidateStaleConversationsJob | 25 | `app/jobs/consolidate_stale_conversations_job.rb` |
| ConsolidateConversationJob | 130 | `app/jobs/consolidate_conversation_job.rb` |
| Recurring job config | 5 | `config/recurring.yml` |
| Tests | ~120 | `test/jobs/*_test.rb` |
| **Total** | **~290** | |

---

## 10. Security Considerations

- **Rate limiting implicit**: Hourly job with 6-hour idle threshold prevents over-processing
- **No user data leakage**: Memories scoped to specific agents via `agent.memories.create`
- **LLM API key security**: Uses existing RubyLLM configuration
- **Content limits**: AgentMemory model validates content length (10k chars)

---

## 11. Cost Considerations

- **Cost varies by agent model**: Each agent uses its own model for extraction
  - GPT-4o: ~$2.50/1M input, ~$10/1M output
  - Claude Sonnet: ~$3/1M input, ~$15/1M output
  - Claude Haiku: ~$0.25/1M input, ~$1.25/1M output
- 100k token chunk ≈ $0.30-$3 per chunk per agent depending on model
- Most conversations will be < 100k tokens = single chunk
- Only runs on idle group chats, not all conversations
- Consider cheaper agent models for agents expected to have high conversation volume

---

## 12. Future Enhancements (Out of Scope)

- Admin UI to view consolidation history
- Manual "consolidate now" button
- Configurable extraction prompt per account
- Metrics on memories extracted per conversation
