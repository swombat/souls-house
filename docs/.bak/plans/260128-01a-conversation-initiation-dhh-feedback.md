# DHH Code Review: Conversation Initiation Spec

## Overall Assessment

This spec commits the cardinal sin of over-engineering: it proposes a **685-line solution** for what should be a **200-line feature**. The architecture diagram alone should set off alarm bells. Two new jobs, two new tools, counter caching, callback chains, complex prompt templates with ERB - it reads like someone who learned about every Rails pattern and felt obligated to use them all.

The core insight is simple: "Agents should occasionally start conversations." The implementation should match that simplicity. Instead, we have an agentic loop with tool-based decision making, when a single LLM call returning structured output would suffice.

**This spec is not Rails-worthy. It needs significant simplification.**

---

## Critical Issues

### 1. The "Agentic Loop" is Needless Complexity

The spec proposes:
- `FetchConversationDetailsTool` - so the agent can "fetch more details"
- `InitiationDecisionTool` - so the agent can "make its decision"
- An LLM that runs in an agentic loop with tools

But why? The agent already receives conversation summaries in the prompt. The "decision" is one of three options: continue, initiate, or nothing. This is a **single LLM call returning structured JSON**, not an agentic workflow.

```ruby
# What the spec proposes: ~350 lines across two tools
llm.with_tool(FetchConversationDetailsTool.new(...))
   .with_tool(InitiationDecisionTool.new(...))
   .complete

# What it should be: 20 lines
response = RubyLLM.chat(model: agent.model_id)
                  .complete(prompt, response_format: :json)
decision = JSON.parse(response.content)
execute_decision(decision)
```

The tools add nothing but complexity. The agent doesn't need to "fetch" conversation details - you already provided them. The agent doesn't need a "tool" to make a decision - it just needs to return its decision.

### 2. Counter Cache on `pending_initiations_count` is a Code Smell

The spec adds `pending_initiations_count` to agents and maintains it with:
- `increment!` on initiation
- A callback in Message to `decrement!` on first human response
- Checking "is this the first human response" via `human_message_count > 1`

This is fragile. What happens if:
- A message is deleted?
- A chat is archived before a human responds?
- The job fails between creating the chat and incrementing the counter?

**You don't need a counter. You need a query.**

```ruby
# The spec's approach: maintain a counter, hope nothing breaks
agent.pending_initiations_count >= HARD_CAP

# The Rails way: just ask the database
def at_hard_cap?
  agent.chats.initiated
       .without_human_response
       .count >= HARD_CAP
end
```

Add a scope on Chat for `initiated` and `without_human_response`. The database is the source of truth. Counters lie.

### 3. Separate Sweep Job and Decision Job is Unnecessary

The spec splits this into:
- `ConversationInitiationSweepJob` - runs hourly, spawns per-agent jobs
- `AgentInitiationDecisionJob` - runs per-agent

This creates complexity around staggered execution (random delays), job coordination, and two places to understand. But the entire sweep will take seconds. Just do it all in one job:

```ruby
class ConversationInitiationJob < ApplicationJob
  def perform
    return unless daytime?

    eligible_agents.find_each do |agent|
      next if agent.at_initiation_cap?
      process_agent(agent)
    end
  end

  private

  def process_agent(agent)
    decision = get_agent_decision(agent)
    execute_decision(agent, decision)
  rescue StandardError => e
    Rails.logger.error "Initiation failed for agent #{agent.id}: #{e.message}"
  end
end
```

If you're worried about one agent's failure affecting others, rescue exceptions per-agent. You don't need job-level isolation for this.

### 4. Two New Database Columns on `agents` Are Unnecessary

The spec adds:
- `pending_initiations_count` - counter cache (already addressed above)
- `last_initiation_at` - for rate limiting

But `last_initiation_at` is just `agent.chats.initiated.maximum(:created_at)`. Don't store what you can derive.

### 5. The Prompt Template Is Over-Engineered

The spec shows ERB templates with sections for:
- Agent identity
- Memory context
- Conversation list with summaries
- Human activity
- Recent initiations
- Rate limiting guidance
- Decision instructions

This is a lot of ceremony. Look at how `ManualAgentResponseJob` builds context - it calls `chat.build_context_for_agent(agent)`, which lives in the model where it belongs.

The initiation prompt should be a simple method on Agent:

```ruby
class Agent < ApplicationRecord
  def build_initiation_prompt(continuable_conversations:)
    parts = []
    parts << system_prompt
    parts << memory_context
    parts << format_continuable_conversations(continuable_conversations)
    parts << initiation_instructions
    parts.compact.join("\n\n")
  end
end
```

---

## Improvements Needed

### 1. Replace Tools with Structured Output

Instead of an agentic loop with tools, use structured JSON output:

```ruby
def get_agent_decision(agent)
  prompt = agent.build_initiation_prompt(
    continuable_conversations: agent.continuable_conversations
  )

  response = RubyLLM.chat(model: agent.model_id, provider: :openrouter)
                    .with_response_format(:json)
                    .ask(prompt)

  JSON.parse(response.content).symbolize_keys
end
```

Expected response format:
```json
{
  "action": "initiate",
  "topic": "Weekly check-in",
  "message": "Hello everyone...",
  "reason": "It's been a week since we discussed progress"
}
```

### 2. Replace Counter Cache with Scopes

On Chat:

```ruby
scope :initiated, -> { where.not(initiated_by_agent_id: nil) }
scope :without_human_response, -> {
  where.not(id: Message.where(role: "user").where.not(user_id: nil).select(:chat_id))
}
```

On Agent:

```ruby
def pending_initiated_conversations
  chats.initiated.where(initiated_by_agent: self).without_human_response
end

def at_initiation_cap?
  pending_initiated_conversations.count >= 2
end
```

### 3. Consolidate to One Job

```ruby
class ConversationInitiationJob < ApplicationJob
  DAYTIME_HOURS = (9..20).freeze

  def perform
    return unless daytime?

    eligible_agents.find_each do |agent|
      process_agent(agent) unless agent.at_initiation_cap?
    rescue StandardError => e
      log_failure(agent, e)
    end
  end

  private

  def daytime?
    DAYTIME_HOURS.include?(Time.current.in_time_zone("GMT").hour)
  end

  def eligible_agents
    Agent.active
         .joins(:account)
         .where(accounts: { id: active_account_ids })
  end

  def process_agent(agent)
    decision = get_agent_decision(agent)
    execute_decision(agent, decision)
    audit(agent, decision)
  end

  def execute_decision(agent, decision)
    case decision[:action]
    when "continue"
      continue_conversation(agent, decision)
    when "initiate"
      initiate_conversation(agent, decision)
    end
  end
end
```

### 4. Move Domain Logic to Models

The `create_initiated_conversation` logic belongs on Chat:

```ruby
class Chat
  def self.initiate_by_agent!(agent, topic:, message:, reason:)
    transaction do
      chat = agent.account.chats.create!(
        title: topic,
        manual_responses: true,
        model_id: agent.model_id,
        initiated_by_agent: agent,
        initiation_reason: reason
      )
      chat.agents << agent
      chat.messages.create!(role: "assistant", agent: agent, content: message)
      chat
    end
  end
end
```

### 5. Remove Unnecessary Database Columns

The only columns needed are on `chats`:
- `initiated_by_agent_id` - who started it
- `initiation_reason` - why (optional, could be in audit log instead)

Remove from the spec:
- `agents.pending_initiations_count`
- `agents.last_initiation_at`

---

## What Works Well

1. **The core concept is sound**: Having agents proactively initiate conversations is a valuable feature. The hourly sweep during daytime hours is sensible.

2. **The audit logging approach is correct**: Logging decisions to AuditLog for review is the right pattern.

3. **The database schema for `initiated_by_agent_id` is appropriate**: Tracking who initiated a conversation on the Chat record is the right place.

4. **The rate limiting concept is right**: Limiting to 2 pending initiations per agent prevents spam. The implementation just needs to be simpler.

5. **The test structure is reasonable**: The tests cover the right scenarios, even if they're testing the wrong architecture.

---

## Refactored Version

Here's what a Rails-worthy implementation looks like:

### Migration

```ruby
class AddInitiationToChats < ActiveRecord::Migration[8.1]
  def change
    add_reference :chats, :initiated_by_agent, foreign_key: { to_table: :agents }
    add_column :chats, :initiation_reason, :text
  end
end
```

### Model Changes

```ruby
# app/models/chat.rb
class Chat < ApplicationRecord
  belongs_to :initiated_by_agent, class_name: "Agent", optional: true

  scope :initiated, -> { where.not(initiated_by_agent_id: nil) }
  scope :awaiting_human_response, -> {
    initiated.where.not(
      id: Message.where(role: "user").where.not(user_id: nil).select(:chat_id)
    )
  }

  def self.initiate_by_agent!(agent, topic:, message:, reason: nil)
    transaction do
      chat = agent.account.chats.create!(
        title: topic,
        manual_responses: true,
        model_id: agent.model_id,
        initiated_by_agent: agent,
        initiation_reason: reason
      )
      chat.agents << agent
      chat.messages.create!(role: "assistant", agent: agent, content: message)
      chat
    end
  end
end

# app/models/agent.rb
class Agent < ApplicationRecord
  INITIATION_CAP = 2

  def at_initiation_cap?
    chats.awaiting_human_response.where(initiated_by_agent: self).count >= INITIATION_CAP
  end

  def continuable_conversations
    chats.active
         .where(manual_responses: true)
         .where.not(id: last_responded_chat_ids)
         .includes(:messages)
         .limit(10)
  end

  def build_initiation_prompt(conversations:)
    <<~PROMPT
      #{system_prompt}

      #{memory_context}

      # Current Time
      #{Time.current.strftime('%Y-%m-%d %H:%M %Z')}

      # Conversations You Could Continue
      #{format_conversations(conversations)}

      # Your Task
      Decide whether to:
      1. Continue an existing conversation
      2. Start a new conversation
      3. Do nothing this cycle

      Respond with JSON:
      {"action": "continue|initiate|nothing", "conversation_id": "...", "topic": "...", "message": "...", "reason": "..."}
    PROMPT
  end

  private

  def last_responded_chat_ids
    Message.where(agent: self, role: "assistant")
           .group(:chat_id)
           .having("MAX(created_at) = (SELECT MAX(created_at) FROM messages WHERE chat_id = messages.chat_id)")
           .select(:chat_id)
  end

  def format_conversations(conversations)
    return "No conversations available." if conversations.empty?

    conversations.map do |chat|
      "- #{chat.title_or_default} (#{chat.obfuscated_id}): #{chat.summary || 'No summary'}"
    end.join("\n")
  end
end
```

### The Job

```ruby
# app/jobs/conversation_initiation_job.rb
class ConversationInitiationJob < ApplicationJob
  DAYTIME_HOURS = (9..20).freeze
  ACTIVE_THRESHOLD = 7.days

  retry_on RubyLLM::ServerError, wait: :polynomially_longer, attempts: 3
  retry_on RubyLLM::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform
    return unless daytime?

    eligible_agents.find_each do |agent|
      process_agent(agent)
    rescue StandardError => e
      Rails.logger.error "[ConversationInitiation] Agent #{agent.id} failed: #{e.message}"
    end
  end

  private

  def daytime?
    DAYTIME_HOURS.include?(Time.current.in_time_zone("GMT").hour)
  end

  def eligible_agents
    Agent.active
         .joins(account: :audit_logs)
         .where(audit_logs: { created_at: ACTIVE_THRESHOLD.ago.. })
         .distinct
  end

  def process_agent(agent)
    return if agent.at_initiation_cap?

    decision = get_decision(agent)
    execute_decision(agent, decision)
    audit_decision(agent, decision)
  end

  def get_decision(agent)
    conversations = agent.continuable_conversations
    prompt = agent.build_initiation_prompt(conversations: conversations)

    response = RubyLLM.chat(model: agent.model_id, provider: :openrouter, assume_model_exists: true)
                      .ask(prompt)

    JSON.parse(response.content).symbolize_keys
  rescue JSON::ParserError
    { action: "nothing", reason: "Failed to parse response" }
  end

  def execute_decision(agent, decision)
    case decision[:action]
    when "continue"
      chat = agent.account.chats.find_by(id: Chat.decode_id(decision[:conversation_id]))
      ManualAgentResponseJob.perform_later(chat, agent) if chat&.respondable?
    when "initiate"
      Chat.initiate_by_agent!(
        agent,
        topic: decision[:topic],
        message: decision[:message],
        reason: decision[:reason]
      )
    end
  end

  def audit_decision(agent, decision)
    AuditLog.create!(
      account: agent.account,
      action: "agent_initiation_#{decision[:action]}",
      auditable: agent,
      data: decision.slice(:topic, :reason, :conversation_id)
    )
  end
end
```

### recurring.yml

```yaml
production:
  conversation_initiation:
    class: ConversationInitiationJob
    schedule: every hour at minute 0
```

---

## Summary

| Aspect | Spec Proposes | Should Be |
|--------|--------------|-----------|
| Lines of Code | ~685 | ~200 |
| Jobs | 2 | 1 |
| Tools | 2 | 0 |
| New Agent Columns | 2 | 0 |
| New Chat Columns | 2 | 2 |
| Callbacks | 1 (in Message) | 0 |
| LLM Calls | Multiple (agentic loop) | 1 (structured output) |

The refactored version is:
- **70% smaller**
- **No counter caches to maintain**
- **No callback chains**
- **No tool abstraction layer**
- **Fat model, skinny job**

This is the Rails way: simple, direct, and honest about what it does.
