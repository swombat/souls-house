# Conversation Initiation Feature

## Executive Summary

This feature enables AI agents to proactively initiate or continue conversations with users, creating a more dynamic and engaging experience. The system runs hourly during daytime hours (9am-9pm GMT), evaluating each agent in active accounts to determine if they want to start a new conversation or continue an existing one.

The implementation follows an agentic loop pattern where the agent uses tools to gather information about conversations and make decisions. This approach gives agents autonomy while maintaining appropriate rate limiting and human oversight.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Hourly Recurring Job                          │
│                  (9am-9pm GMT only)                              │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│              ConversationInitiationSweepJob                      │
│  - Find active accounts (recent audit log + recent message)      │
│  - For each account with agents, spawn per-agent jobs            │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼ (staggered with random delay 1-20 min)
┌─────────────────────────────────────────────────────────────────┐
│              AgentInitiationDecisionJob                          │
│  - Check hard cap (2 unresponded initiations)                    │
│  - Build decision prompt with:                                   │
│    - Agent identity & memories                                   │
│    - Recent conversation summaries                               │
│    - Human activity timestamps                                   │
│    - Recent initiation history                                   │
│  - Run agentic loop with tools                                   │
└──────────────────────────┬──────────────────────────────────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
         ┌────────┐  ┌──────────┐  ┌────────────┐
         │Continue│  │ Initiate │  │  Do       │
         │Existing│  │   New    │  │ Nothing   │
         └───┬────┘  └────┬─────┘  └─────┬─────┘
             │            │              │
             ▼            ▼              ▼
      ManualAgent     Create Chat    Log Journal
      ResponseJob   + First Message    Memory
```

## Data Model Changes

### 1. New Column on `agents` Table

Track agent initiation state for rate limiting:

```ruby
# Migration: db/migrate/XXXXXX_add_initiation_tracking_to_agents.rb
class AddInitiationTrackingToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :pending_initiations_count, :integer, default: 0, null: false
    add_column :agents, :last_initiation_at, :datetime
  end
end
```

**Fields:**
- `pending_initiations_count` - Number of agent-initiated conversations awaiting human response (hard cap is 2)
- `last_initiation_at` - Timestamp of the last conversation this agent initiated

### 2. New Column on `chats` Table

Track who initiated the conversation:

```ruby
# Migration: db/migrate/XXXXXX_add_initiated_by_to_chats.rb
class AddInitiatedByToChats < ActiveRecord::Migration[8.1]
  def change
    add_reference :chats, :initiated_by_agent, foreign_key: { to_table: :agents }, index: true
    add_column :chats, :initiation_reason, :text
  end
end
```

**Fields:**
- `initiated_by_agent_id` - The agent that created this conversation (nil for human-created)
- `initiation_reason` - Why the agent chose to initiate this conversation

### 3. Index for Efficient Queries

```ruby
add_index :chats, [:initiated_by_agent_id, :created_at],
          where: "initiated_by_agent_id IS NOT NULL"
add_index :messages, [:chat_id, :user_id, :created_at]
```

## Job Architecture

### 1. ConversationInitiationSweepJob

The hourly sweep job that finds eligible accounts and spawns per-agent jobs.

```ruby
# app/jobs/conversation_initiation_sweep_job.rb
class ConversationInitiationSweepJob < ApplicationJob
  queue_as :default

  DAYTIME_HOURS = (9..20).freeze  # 9am-9pm GMT (20 = 8pm, so 20:59 is last valid)
  ACTIVE_THRESHOLD = 7.days

  def perform
    return unless daytime_in_gmt?

    active_accounts_with_agents.find_each do |account|
      account.agents.active.find_each do |agent|
        delay_minutes = rand(1..20)
        AgentInitiationDecisionJob.set(wait: delay_minutes.minutes).perform_later(agent)
      end
    end
  end

  private

  def daytime_in_gmt?
    DAYTIME_HOURS.include?(Time.current.in_time_zone("GMT").hour)
  end

  def active_accounts_with_agents
    recent_audit = AuditLog.where(created_at: ACTIVE_THRESHOLD.ago..)
                           .where.not(account_id: nil)
                           .select(:account_id)

    recent_message = Message.joins(:chat)
                            .where(created_at: ACTIVE_THRESHOLD.ago..)
                            .where.not(user_id: nil)
                            .select("chats.account_id")

    Account.where(id: recent_audit)
           .or(Account.where(id: recent_message))
           .joins(:agents)
           .where(agents: { active: true })
           .distinct
  end
end
```

### 2. AgentInitiationDecisionJob

The per-agent job that runs the decision loop.

```ruby
# app/jobs/agent_initiation_decision_job.rb
class AgentInitiationDecisionJob < ApplicationJob
  queue_as :default

  retry_on RubyLLM::ServerError, wait: :polynomially_longer, attempts: 3
  retry_on RubyLLM::RateLimitError, wait: :polynomially_longer, attempts: 5

  HARD_CAP = 2
  RECENTLY_INITIATED_WINDOW = 48.hours

  def perform(agent)
    @agent = agent
    @account = agent.account

    audit_decision_start

    if at_hard_cap?
      audit_decision("skipped_hard_cap", { pending_count: agent.pending_initiations_count })
      log_journal_memory("Skipped initiation check - already have #{agent.pending_initiations_count} conversations awaiting human response.")
      return
    end

    run_decision_loop
  end

  private

  def at_hard_cap?
    @agent.pending_initiations_count >= HARD_CAP
  end

  def run_decision_loop
    llm = build_llm_with_tools

    context = build_decision_context
    context.each { |msg| llm.add_message(msg) }

    llm.complete
  end

  def build_llm_with_tools
    llm = RubyLLM.chat(
      model: @agent.model_id,
      provider: :openrouter,
      assume_model_exists: true
    )

    [
      FetchConversationDetailsTool,
      InitiationDecisionTool
    ].each do |tool_class|
      tool = tool_class.new(agent: @agent, account: @account, job: self)
      llm = llm.with_tool(tool)
    end

    llm.on_end_message { |msg| handle_loop_end(msg) }

    llm
  end

  def build_decision_context
    [
      { role: "system", content: build_system_prompt },
      { role: "user", content: build_decision_request }
    ]
  end

  def build_system_prompt
    parts = []

    parts << agent_identity_section
    parts << agent_memory_section if @agent.memory_context
    parts << "Current time: #{Time.current.strftime('%Y-%m-%d %H:%M %Z')}"

    parts.compact.join("\n\n")
  end

  def build_decision_request
    parts = []

    parts << conversation_list_section
    parts << human_activity_section
    parts << recent_initiations_section
    parts << rate_limiting_guidance
    parts << decision_instructions

    parts.join("\n\n")
  end

  # ... helper methods for building prompt sections

  def audit_decision_start
    AuditLog.create!(
      account: @account,
      action: "agent_initiation_check_started",
      auditable: @agent,
      data: { pending_initiations: @agent.pending_initiations_count }
    )
  end

  def audit_decision(action, data = {})
    AuditLog.create!(
      account: @account,
      action: action,
      auditable: @agent,
      data: data
    )
  end

  def log_journal_memory(content)
    @agent.memories.create!(
      content: content,
      memory_type: :journal
    )
  end

  def handle_loop_end(msg)
    # Tool execution handles the actual decision
    # This is called when the LLM finishes responding
  end
end
```

## Tools

### 1. FetchConversationDetailsTool

Allows the agent to fetch more details about a specific conversation.

```ruby
# app/tools/fetch_conversation_details_tool.rb
class FetchConversationDetailsTool < RubyLLM::Tool
  description "Fetch detailed information about a conversation, including the last 10 messages. Use this to decide whether to continue a conversation."

  param :conversation_id, type: :string,
        desc: "The ID of the conversation to fetch details for",
        required: true

  def initialize(agent: nil, account: nil, job: nil)
    super()
    @agent = agent
    @account = account
    @job = job
  end

  def execute(conversation_id:)
    chat = @account.chats.find_by(id: Chat.decode_id(conversation_id))

    return { error: "Conversation not found" } unless chat
    return { error: "You are not a participant in this conversation" } unless chat.agents.include?(@agent)

    messages = chat.messages
                   .includes(:user, :agent)
                   .order(created_at: :desc)
                   .limit(10)
                   .reverse

    {
      id: chat.obfuscated_id,
      title: chat.title_or_default,
      summary: chat.summary,
      last_message_at: chat.messages.maximum(:created_at)&.iso8601,
      participants: format_participants(chat),
      recent_messages: messages.map { |m| format_message(m) }
    }
  end

  private

  def format_participants(chat)
    humans = chat.messages.joins(:user).distinct.pluck("users.email_address")
                 .map { |email| { type: "human", name: email.split("@").first } }

    agents = chat.agents.map { |a| { type: "agent", name: a.name } }

    humans + agents
  end

  def format_message(message)
    {
      role: message.role,
      author: message.author_name,
      content: message.content&.truncate(500),
      timestamp: message.created_at.iso8601
    }
  end
end
```

### 2. InitiationDecisionTool

The tool the agent uses to make its final decision.

```ruby
# app/tools/initiation_decision_tool.rb
class InitiationDecisionTool < RubyLLM::Tool
  description <<~DESC
    Make your decision about conversation initiation. You must call this tool exactly once.

    Actions:
    - continue: Continue an existing conversation (provide conversation_id)
    - initiate: Start a new conversation (provide topic, reason, and invited_agent_names)
    - nothing: Do nothing this cycle (provide reason)
  DESC

  param :action, type: :string,
        desc: "One of: continue, initiate, nothing",
        required: true

  param :conversation_id, type: :string,
        desc: "For 'continue' action: the ID of the conversation to continue",
        required: false

  param :topic, type: :string,
        desc: "For 'initiate' action: the topic/title of the new conversation",
        required: false

  param :reason, type: :string,
        desc: "For 'initiate' or 'nothing': why you made this decision",
        required: true

  param :invited_agent_names, type: :array,
        desc: "For 'initiate' action: names of other agents to invite (optional)",
        required: false

  param :initial_message, type: :string,
        desc: "For 'initiate' action: your opening message to start the conversation",
        required: false

  def initialize(agent: nil, account: nil, job: nil)
    super()
    @agent = agent
    @account = account
    @job = job
  end

  def execute(action:, reason:, conversation_id: nil, topic: nil, invited_agent_names: nil, initial_message: nil)
    case action
    when "continue"
      handle_continue(conversation_id, reason)
    when "initiate"
      handle_initiate(topic, reason, invited_agent_names, initial_message)
    when "nothing"
      handle_nothing(reason)
    else
      { error: "Invalid action: #{action}. Must be one of: continue, initiate, nothing" }
    end
  end

  private

  def handle_continue(conversation_id, reason)
    return { error: "conversation_id required for continue action" } if conversation_id.blank?

    chat = @account.chats.find_by(id: Chat.decode_id(conversation_id))
    return { error: "Conversation not found" } unless chat
    return { error: "Conversation is not respondable" } unless chat.respondable?
    return { error: "You are not a participant" } unless chat.agents.include?(@agent)

    audit("agent_continued_conversation", {
      chat_id: chat.id,
      reason: reason
    })

    # Trigger the normal response flow
    ManualAgentResponseJob.perform_later(chat, @agent)

    {
      success: true,
      action: "continue",
      message: "Continuing conversation: #{chat.title_or_default}"
    }
  end

  def handle_initiate(topic, reason, invited_agent_names, initial_message)
    return { error: "topic required for initiate action" } if topic.blank?
    return { error: "initial_message required for initiate action" } if initial_message.blank?

    invited_agents = resolve_invited_agents(invited_agent_names)

    chat = create_initiated_conversation(topic, reason, invited_agents, initial_message)

    # Update tracking
    @agent.increment!(:pending_initiations_count)
    @agent.update!(last_initiation_at: Time.current)

    audit("agent_initiated_conversation", {
      chat_id: chat.id,
      topic: topic,
      reason: reason,
      invited_agents: invited_agents.map(&:name)
    })

    # Trigger responses from other invited agents
    if invited_agents.any?
      other_agent_ids = invited_agents.reject { |a| a.id == @agent.id }.map(&:id)
      AllAgentsResponseJob.perform_later(chat, other_agent_ids) if other_agent_ids.any?
    end

    {
      success: true,
      action: "initiate",
      conversation_id: chat.obfuscated_id,
      message: "Created new conversation: #{topic}"
    }
  end

  def handle_nothing(reason)
    audit("agent_skipped_initiation", { reason: reason })

    # Log a journal memory about the decision
    @agent.memories.create!(
      content: "Decided not to initiate conversation: #{reason}",
      memory_type: :journal
    )

    {
      success: true,
      action: "nothing",
      message: "Noted. No action taken this cycle."
    }
  end

  def resolve_invited_agents(names)
    return [@agent] if names.blank?

    agents = @account.agents.active.where(name: names)

    # Always include the initiating agent
    agents.include?(@agent) ? agents : agents + [@agent]
  end

  def create_initiated_conversation(topic, reason, agents, initial_message)
    Chat.transaction do
      chat = @account.chats.create!(
        title: topic,
        manual_responses: true,
        model_id: @agent.model_id,
        initiated_by_agent: @agent,
        initiation_reason: reason
      )

      chat.agent_ids = agents.map(&:id)
      chat.save!

      # Create the agent's opening message
      chat.messages.create!(
        role: "assistant",
        agent: @agent,
        content: initial_message
      )

      chat
    end
  end

  def audit(action, data)
    AuditLog.create!(
      account: @account,
      action: action,
      auditable: @agent,
      data: data
    )
  end
end
```

## Prompt Design

### System Prompt Structure

```erb
# Your Identity

You are <%= @agent.name %>.

<%= @agent.system_prompt %>

<% if @agent.memory_context %>
<%= @agent.memory_context %>
<% end %>

# Current Context

Current time: <%= Time.current.strftime('%Y-%m-%d %H:%M %Z') %>

You are being asked to decide whether to initiate or continue a conversation with the humans in your account.
```

### Decision Request Prompt

```erb
# Conversations You Can Continue

These are conversations you're part of where you weren't the last to respond:

<% @continuable_conversations.each do |chat| %>
## <%= chat.title_or_default %> (ID: <%= chat.obfuscated_id %>)
- Last message: <%= chat.messages.maximum(:created_at)&.strftime('%Y-%m-%d %H:%M') %><% if chat.messages.maximum(:created_at) < 48.hours.ago %> [INACTIVE - no messages for 48+ hours]<% end %>
- Summary: <%= chat.summary || "No summary available" %>
- Your last response: <%= last_agent_message_time(chat) %>
<% end %>

<% if @continuable_conversations.empty? %>
No conversations currently awaiting your response.
<% end %>

# Human Activity

Recent activity from humans in this account:
<% @human_activity.each do |user, timestamp| %>
- <%= user.full_name || user.email_address.split("@").first %>: last active <%= time_ago_in_words(timestamp) %> ago
<% end %>

# Recent Initiations

<% if @recent_initiations.any? %>
Conversations initiated by agents in the last 48 hours:
<% @recent_initiations.each do |chat| %>
- "<%= chat.title %>" by <%= chat.initiated_by_agent.name %> (<%= time_ago_in_words(chat.created_at) %> ago)
  - Human responses: <%= chat.messages.where.not(user_id: nil).count %>
<% end %>
<% else %>
No agent-initiated conversations in the last 48 hours.
<% end %>

Your last initiation: <%= @agent.last_initiation_at ? "#{time_ago_in_words(@agent.last_initiation_at)} ago" : "Never" %>
<% if @agent.pending_initiations_count > 0 %>
You have <%= @agent.pending_initiations_count %> initiated conversation(s) still awaiting human response.
<% end %>

# Guidelines

- Both individual agents and the group should avoid initiating too many conversations at once
- Consider whether humans have been active recently before initiating
- If continuing a conversation, make sure you have something meaningful to add
- Inactive conversations (48+ hours) may be worth reviving only if you have something important to discuss
- You can use the fetch_conversation_details tool to see recent messages before deciding

# Your Decision

Use the initiation_decision tool to make your choice:
- "continue" - to respond to an existing conversation
- "initiate" - to start a new conversation on a topic you find important
- "nothing" - if now isn't the right time

You must call the initiation_decision tool exactly once.
```

## Flow Diagrams

### Continue Existing Conversation

```
Agent calls InitiationDecisionTool(action: "continue", conversation_id: "abc123")
    │
    ▼
Validate conversation exists and agent is participant
    │
    ▼
Create AuditLog: "agent_continued_conversation"
    │
    ▼
Queue ManualAgentResponseJob(chat, agent)
    │
    ▼
ManualAgentResponseJob runs normal response flow
    │
    ▼
Agent posts response in conversation
```

### Initiate New Conversation

```
Agent calls InitiationDecisionTool(action: "initiate", topic: "...", initial_message: "...")
    │
    ▼
Create Chat with:
  - title = topic
  - initiated_by_agent = agent
  - initiation_reason = reason
  - manual_responses = true
    │
    ▼
Add agent (and any invited agents) to chat_agents
    │
    ▼
Create Message with agent's initial_message
    │
    ▼
Increment agent.pending_initiations_count
Update agent.last_initiation_at
    │
    ▼
Create AuditLog: "agent_initiated_conversation"
    │
    ▼
If other agents invited:
    Queue AllAgentsResponseJob for other agents
    │
    ▼
Conversation is live, awaiting human response
```

### Do Nothing

```
Agent calls InitiationDecisionTool(action: "nothing", reason: "...")
    │
    ▼
Create AuditLog: "agent_skipped_initiation"
    │
    ▼
Create AgentMemory (journal): "Decided not to initiate: {reason}"
    │
    ▼
Job completes
```

## Audit Events

| Action | Description | Data Fields |
|--------|-------------|-------------|
| `agent_initiation_check_started` | Agent's decision job began | `pending_initiations` |
| `agent_initiated_conversation` | Agent created a new conversation | `chat_id`, `topic`, `reason`, `invited_agents` |
| `agent_continued_conversation` | Agent chose to continue existing chat | `chat_id`, `reason` |
| `agent_skipped_initiation` | Agent chose to do nothing | `reason` |
| `skipped_hard_cap` | Job skipped due to rate limit | `pending_count` |

## Pending Initiation Count Management

The `pending_initiations_count` needs to be decremented when a human responds.

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  after_create_commit :check_human_response_to_initiated_chat, if: :human_message?

  private

  def human_message?
    user_id.present? && role == "user"
  end

  def check_human_response_to_initiated_chat
    return unless chat.initiated_by_agent_id.present?

    initiating_agent = chat.initiated_by_agent
    return if initiating_agent.pending_initiations_count <= 0

    # Only decrement if this is the first human response to this initiated chat
    human_message_count = chat.messages.where.not(user_id: nil).count
    return if human_message_count > 1

    initiating_agent.decrement!(:pending_initiations_count)
  end
end
```

## Recurring Job Configuration

```yaml
# config/recurring.yml (add to existing)
production:
  conversation_initiation_sweep:
    class: ConversationInitiationSweepJob
    schedule: every hour at minute 0
```

## Edge Cases and Error Handling

### Hard Cap Logic

```ruby
def at_hard_cap?
  @agent.pending_initiations_count >= HARD_CAP
end
```

The agent still runs through the job even at hard cap, but:
1. An audit log records that it was skipped
2. A journal memory is logged so the agent knows why
3. No LLM call is made (cost savings)

### Conversation Not Respondable

If an agent tries to continue an archived/deleted conversation:
- Tool returns error message
- Agent should call tool again with different choice
- LLM will naturally try another approach

### Agent Not Active

The sweep job only queries `agents.active`, so inactive agents are never selected.

### Account No Longer Active

The sweep job checks for recent audit logs and messages within the threshold period.

### Duplicate Initiations

Race condition prevention: The job uses `perform_later` with random delay, making exact duplicates unlikely. The hard cap provides additional protection.

### LLM Errors

Standard retry logic from existing jobs:
- `RubyLLM::ServerError` - exponential backoff, 3 attempts
- `RubyLLM::RateLimitError` - exponential backoff, 5 attempts

## Testing Strategy

### Unit Tests

```ruby
# test/jobs/conversation_initiation_sweep_job_test.rb
class ConversationInitiationSweepJobTest < ActiveSupport::TestCase
  test "only runs during daytime GMT hours" do
    travel_to Time.zone.parse("2026-01-28 03:00 GMT") do
      assert_no_enqueued_jobs do
        ConversationInitiationSweepJob.perform_now
      end
    end
  end

  test "spawns jobs for active agents in active accounts" do
    account = accounts(:active_account)
    agent = account.agents.create!(name: "Test Agent", active: true)

    # Create recent activity
    AuditLog.create!(account: account, action: "test", created_at: 1.day.ago)

    travel_to Time.zone.parse("2026-01-28 12:00 GMT") do
      assert_enqueued_with(job: AgentInitiationDecisionJob) do
        ConversationInitiationSweepJob.perform_now
      end
    end
  end

  test "skips accounts without recent activity" do
    account = accounts(:stale_account)
    agent = account.agents.create!(name: "Test Agent", active: true)

    travel_to Time.zone.parse("2026-01-28 12:00 GMT") do
      assert_no_enqueued_jobs do
        ConversationInitiationSweepJob.perform_now
      end
    end
  end
end
```

```ruby
# test/jobs/agent_initiation_decision_job_test.rb
class AgentInitiationDecisionJobTest < ActiveSupport::TestCase
  test "skips agent at hard cap" do
    agent = agents(:capped_agent)
    agent.update!(pending_initiations_count: 2)

    AgentInitiationDecisionJob.perform_now(agent)

    assert AuditLog.exists?(action: "skipped_hard_cap", auditable: agent)
  end

  test "creates audit log on start" do
    VCR.use_cassette("initiation/decision_loop") do
      agent = agents(:active_agent)

      AgentInitiationDecisionJob.perform_now(agent)

      assert AuditLog.exists?(action: "agent_initiation_check_started", auditable: agent)
    end
  end
end
```

```ruby
# test/tools/initiation_decision_tool_test.rb
class InitiationDecisionToolTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:one)
    @agent = agents(:one)
    @tool = InitiationDecisionTool.new(agent: @agent, account: @account)
  end

  test "continue action triggers response job" do
    chat = chats(:group_chat)
    chat.agents << @agent unless chat.agents.include?(@agent)

    result = @tool.execute(
      action: "continue",
      conversation_id: chat.obfuscated_id,
      reason: "Want to follow up"
    )

    assert result[:success]
    assert_equal "continue", result[:action]
    assert_enqueued_with(job: ManualAgentResponseJob)
  end

  test "initiate action creates conversation" do
    result = @tool.execute(
      action: "initiate",
      topic: "Weekly Check-in",
      reason: "Time to discuss progress",
      initial_message: "Hello everyone, I wanted to check in about our progress this week."
    )

    assert result[:success]
    assert_equal "initiate", result[:action]

    chat = Chat.last
    assert_equal "Weekly Check-in", chat.title
    assert_equal @agent, chat.initiated_by_agent
    assert_equal 1, chat.messages.count
  end

  test "initiate increments pending count" do
    @agent.update!(pending_initiations_count: 0)

    @tool.execute(
      action: "initiate",
      topic: "Test Topic",
      reason: "Testing",
      initial_message: "Hello!"
    )

    assert_equal 1, @agent.reload.pending_initiations_count
  end

  test "nothing action logs memory" do
    result = @tool.execute(
      action: "nothing",
      reason: "No urgent topics to discuss"
    )

    assert result[:success]
    assert @agent.memories.journal.exists?(content: /No urgent topics/)
  end
end
```

### Integration Tests

```ruby
# test/integration/conversation_initiation_flow_test.rb
class ConversationInitiationFlowTest < ActionDispatch::IntegrationTest
  test "human response decrements pending count" do
    agent = agents(:one)
    agent.update!(pending_initiations_count: 1)

    chat = Chat.create!(
      account: agent.account,
      title: "Agent Initiated",
      manual_responses: true,
      initiated_by_agent: agent,
      model_id: "openrouter/auto"
    )
    chat.agents << agent

    # Human responds
    chat.messages.create!(
      role: "user",
      user: users(:one),
      content: "Thanks for starting this conversation!"
    )

    assert_equal 0, agent.reload.pending_initiations_count
  end
end
```

## Implementation Checklist

### Phase 1: Database Migration
- [ ] Create migration for `agents` table (pending_initiations_count, last_initiation_at)
- [ ] Create migration for `chats` table (initiated_by_agent_id, initiation_reason)
- [ ] Run migrations
- [ ] Update Agent model with new columns
- [ ] Update Chat model with new association

### Phase 2: Core Jobs
- [ ] Implement ConversationInitiationSweepJob
- [ ] Implement AgentInitiationDecisionJob
- [ ] Add to recurring.yml

### Phase 3: Tools
- [ ] Implement FetchConversationDetailsTool
- [ ] Implement InitiationDecisionTool

### Phase 4: Supporting Code
- [ ] Add pending count decrement callback to Message model
- [ ] Add helper methods for prompt building

### Phase 5: Testing
- [ ] Unit tests for jobs
- [ ] Unit tests for tools
- [ ] Integration tests for full flow
- [ ] Manual testing in development

### Phase 6: Audit & Monitoring
- [ ] Verify audit logs are created correctly
- [ ] Add any needed indexes for audit log queries

## File Summary

| File | Purpose | LOC (est) |
|------|---------|-----------|
| `db/migrate/XXX_add_initiation_tracking_to_agents.rb` | Agent tracking columns | 10 |
| `db/migrate/XXX_add_initiated_by_to_chats.rb` | Chat initiation tracking | 10 |
| `app/jobs/conversation_initiation_sweep_job.rb` | Hourly sweep | 50 |
| `app/jobs/agent_initiation_decision_job.rb` | Per-agent decision loop | 150 |
| `app/tools/fetch_conversation_details_tool.rb` | Conversation details | 60 |
| `app/tools/initiation_decision_tool.rb` | Decision execution | 120 |
| `config/recurring.yml` | Schedule configuration | 5 |
| `test/jobs/conversation_initiation_sweep_job_test.rb` | Sweep job tests | 50 |
| `test/jobs/agent_initiation_decision_job_test.rb` | Decision job tests | 80 |
| `test/tools/fetch_conversation_details_tool_test.rb` | Tool tests | 50 |
| `test/tools/initiation_decision_tool_test.rb` | Tool tests | 100 |

**Total estimated: ~685 lines of code**

## Security Considerations

1. **Agent Authorization**: Tools verify agent is participant in conversation before allowing actions
2. **Account Scoping**: All queries scoped to agent's account
3. **Rate Limiting**: Hard cap prevents runaway agent initiations
4. **Audit Trail**: All decisions logged for review

## Performance Considerations

1. **Staggered Execution**: Random delays prevent thundering herd
2. **Efficient Queries**: Indexes on frequently queried columns
3. **No N+1**: Use includes/joins in queries
4. **Cost Control**: Skip LLM call when at hard cap
