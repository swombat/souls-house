# Conversation Initiation Feature

## Executive Summary

Agents can proactively initiate or continue conversations with users. An hourly job during daytime hours (9am-9pm GMT) evaluates each agent in active accounts using a single LLM call with structured JSON output.

## Architecture Overview

```
ConversationInitiationJob (hourly, 9am-9pm GMT)
    │
    ▼
For each eligible agent:
    │
    ├─ Skip if at_initiation_cap?
    │
    ├─ Build initiation prompt (model method)
    │
    ├─ Single LLM call → JSON response
    │
    └─ Execute decision: continue | initiate | nothing
```

## Database Changes

One migration, two columns on `chats`:

```ruby
class AddInitiationToChats < ActiveRecord::Migration[8.1]
  def change
    add_reference :chats, :initiated_by_agent, foreign_key: { to_table: :agents }
    add_column :chats, :initiation_reason, :text
  end
end
```

No changes to `agents` table. All state is derived from queries.

## Model Changes

### Chat

```ruby
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
```

### Agent

```ruby
class Agent < ApplicationRecord
  INITIATION_CAP = 2
  RECENTLY_INITIATED_WINDOW = 48.hours

  def at_initiation_cap?
    pending_initiated_conversations.count >= INITIATION_CAP
  end

  def pending_initiated_conversations
    chats.awaiting_human_response.where(initiated_by_agent: self)
  end

  def continuable_conversations
    chats.active.kept
         .where(manual_responses: true)
         .where.not(id: last_responded_chat_ids)
         .includes(:messages)
         .order(updated_at: :desc)
         .limit(10)
  end

  def last_initiation_at
    chats.initiated.where(initiated_by_agent: self).maximum(:created_at)
  end

  def build_initiation_prompt(conversations:, recent_initiations:, human_activity:)
    <<~PROMPT
      #{system_prompt}

      #{memory_context}

      # Current Time
      #{Time.current.strftime('%Y-%m-%d %H:%M %Z')}

      # Conversations You Could Continue
      #{format_conversations(conversations)}

      # Recent Agent Initiations (last 48 hours)
      #{format_recent_initiations(recent_initiations)}

      # Human Activity
      #{format_human_activity(human_activity)}

      # Your Status
      #{initiation_status}

      # Guidelines
      - Avoid initiating too many conversations at once (both you and other agents)
      - Consider human activity before initiating
      - Only continue conversations if you have something meaningful to add
      - Inactive conversations (48+ hours) may be worth reviving only for important topics

      # Your Task
      Decide whether to:
      1. Continue an existing conversation (provide conversation_id)
      2. Start a new conversation (provide topic and opening message)
      3. Do nothing this cycle (provide reason)

      Respond with JSON only:
      {"action": "continue", "conversation_id": "abc123", "reason": "..."}
      {"action": "initiate", "topic": "...", "message": "...", "reason": "..."}
      {"action": "nothing", "reason": "..."}
    PROMPT
  end

  private

  def last_responded_chat_ids
    Message.where(agent: self, role: "assistant")
           .select("DISTINCT ON (chat_id) chat_id")
           .order("chat_id, created_at DESC")
           .joins(:chat)
           .where(chats: { manual_responses: true })
           .where("messages.created_at = (SELECT MAX(m2.created_at) FROM messages m2 WHERE m2.chat_id = messages.chat_id)")
           .pluck(:chat_id)
  end

  def format_conversations(conversations)
    return "No conversations available." if conversations.empty?

    conversations.map do |chat|
      last_at = chat.messages.maximum(:created_at)
      stale = last_at && last_at < 48.hours.ago ? " [INACTIVE 48+ hours]" : ""
      "- #{chat.title_or_default} (#{chat.obfuscated_id})#{stale}: #{chat.summary || 'No summary'}"
    end.join("\n")
  end

  def format_recent_initiations(initiations)
    return "None in the last 48 hours." if initiations.empty?

    initiations.map do |chat|
      human_responses = chat.messages.where(role: "user").where.not(user_id: nil).count
      "- \"#{chat.title}\" by #{chat.initiated_by_agent.name} (#{time_ago(chat.created_at)}) - #{human_responses} human response(s)"
    end.join("\n")
  end

  def format_human_activity(activity)
    return "No recent human activity." if activity.empty?

    activity.map do |user, timestamp|
      name = user.full_name.presence || user.email_address.split("@").first
      "- #{name}: last active #{time_ago(timestamp)}"
    end.join("\n")
  end

  def initiation_status
    pending = pending_initiated_conversations.count
    last = last_initiation_at

    parts = []
    parts << "You have #{pending} initiated conversation(s) awaiting human response." if pending > 0
    parts << "Your last initiation: #{last ? time_ago(last) : 'Never'}"
    parts << "Hard cap: #{INITIATION_CAP} pending initiations (you're at the limit)" if pending >= INITIATION_CAP
    parts.join("\n")
  end

  def time_ago(timestamp)
    distance = Time.current - timestamp
    if distance < 1.hour
      "#{(distance / 60).round} minutes ago"
    elsif distance < 24.hours
      "#{(distance / 1.hour).round} hours ago"
    else
      "#{(distance / 1.day).round} days ago"
    end
  end
end
```

## The Job

```ruby
class ConversationInitiationJob < ApplicationJob
  DAYTIME_HOURS = (9..20).freeze
  ACTIVE_THRESHOLD = 7.days

  retry_on RubyLLM::ServerError, wait: :polynomially_longer, attempts: 3
  retry_on RubyLLM::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform
    return unless daytime?

    eligible_agents.find_each do |agent|
      process_agent(agent)
    rescue => e
      Rails.logger.error "[ConversationInitiation] Agent #{agent.id} failed: #{e.message}"
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
         .distinct
  end

  def active_account_ids
    recent_audit = AuditLog.where(created_at: ACTIVE_THRESHOLD.ago..)
                           .where.not(account_id: nil)
                           .select(:account_id)

    recent_message = Message.joins(:chat)
                            .where(created_at: ACTIVE_THRESHOLD.ago..)
                            .where.not(user_id: nil)
                            .select("chats.account_id")

    Account.where(id: recent_audit).or(Account.where(id: recent_message)).select(:id)
  end

  def process_agent(agent)
    if agent.at_initiation_cap?
      audit(agent, { action: "skipped", reason: "at_hard_cap" })
      return
    end

    decision = get_decision(agent)
    execute_decision(agent, decision)
    audit(agent, decision)
  end

  def get_decision(agent)
    prompt = agent.build_initiation_prompt(
      conversations: agent.continuable_conversations,
      recent_initiations: recent_initiations_for(agent.account),
      human_activity: human_activity_for(agent.account)
    )

    response = RubyLLM.chat(
      model: agent.model_id,
      provider: :openrouter,
      assume_model_exists: true
    ).ask(prompt)

    JSON.parse(response.content).symbolize_keys
  rescue JSON::ParserError
    { action: "nothing", reason: "Failed to parse LLM response" }
  end

  def recent_initiations_for(account)
    account.chats.initiated
           .where(created_at: Agent::RECENTLY_INITIATED_WINDOW.ago..)
           .includes(:initiated_by_agent)
  end

  def human_activity_for(account)
    account.users.joins(:messages)
           .where(messages: { created_at: 7.days.ago.. })
           .group("users.id")
           .select("users.*, MAX(messages.created_at) as last_message_at")
           .map { |u| [u, u.last_message_at] }
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
    when "nothing"
      agent.memories.create!(
        content: "Decided not to initiate: #{decision[:reason]}",
        memory_type: :journal
      )
    end
  end

  def audit(agent, decision)
    AuditLog.create!(
      account: agent.account,
      action: "agent_initiation_#{decision[:action]}",
      auditable: agent,
      data: decision.slice(:topic, :reason, :conversation_id)
    )
  end
end
```

## Recurring Schedule

```yaml
# config/recurring.yml (add to production section)
conversation_initiation:
  class: ConversationInitiationJob
  schedule: every hour at minute 0
```

## Testing Strategy

```ruby
class ConversationInitiationJobTest < ActiveSupport::TestCase
  test "only runs during daytime GMT hours" do
    travel_to Time.zone.parse("2026-01-28 03:00 GMT") do
      ConversationInitiationJob.perform_now
      assert_no_enqueued_jobs
    end
  end

  test "skips agents at hard cap" do
    agent = agents(:one)
    2.times { create_pending_initiation(agent) }

    ConversationInitiationJob.perform_now

    assert AuditLog.exists?(action: "agent_initiation_skipped", auditable: agent)
  end

  test "initiates conversation when agent decides to" do
    VCR.use_cassette("initiation/initiate_decision") do
      agent = agents(:one)

      travel_to Time.zone.parse("2026-01-28 12:00 GMT") do
        ConversationInitiationJob.perform_now
      end

      assert Chat.exists?(initiated_by_agent: agent)
    end
  end
end

class ChatInitiationTest < ActiveSupport::TestCase
  test "initiate_by_agent! creates chat with agent message" do
    agent = agents(:one)

    chat = Chat.initiate_by_agent!(
      agent,
      topic: "Weekly Check-in",
      message: "Hello everyone!",
      reason: "Time to discuss progress"
    )

    assert_equal "Weekly Check-in", chat.title
    assert_equal agent, chat.initiated_by_agent
    assert_equal 1, chat.messages.count
    assert_equal "assistant", chat.messages.first.role
  end
end

class AgentInitiationTest < ActiveSupport::TestCase
  test "at_initiation_cap? returns true when at limit" do
    agent = agents(:one)
    2.times { create_pending_initiation(agent) }

    assert agent.at_initiation_cap?
  end

  test "at_initiation_cap? returns false after human response" do
    agent = agents(:one)
    chat = create_pending_initiation(agent)
    chat.messages.create!(role: "user", user: users(:one), content: "Thanks!")

    refute agent.at_initiation_cap?
  end
end
```

## Implementation Checklist

### Phase 1: Database
- [ ] Create migration for `chats` (initiated_by_agent_id, initiation_reason)
- [ ] Run migration

### Phase 2: Models
- [ ] Add `belongs_to :initiated_by_agent` to Chat
- [ ] Add scopes `initiated` and `awaiting_human_response` to Chat
- [ ] Add `Chat.initiate_by_agent!` class method
- [ ] Add initiation methods to Agent (`at_initiation_cap?`, `continuable_conversations`, etc.)
- [ ] Add `build_initiation_prompt` to Agent

### Phase 3: Job
- [ ] Create ConversationInitiationJob
- [ ] Add to config/recurring.yml

### Phase 4: Testing
- [ ] Unit tests for Chat initiation
- [ ] Unit tests for Agent initiation methods
- [ ] Job tests with VCR cassettes

## File Summary

| File | Purpose | LOC |
|------|---------|-----|
| `db/migrate/XXX_add_initiation_to_chats.rb` | Schema changes | 8 |
| `app/models/chat.rb` | Add scopes and `initiate_by_agent!` | +25 |
| `app/models/agent.rb` | Add initiation methods | +80 |
| `app/jobs/conversation_initiation_job.rb` | Hourly job | 90 |
| `test/jobs/conversation_initiation_job_test.rb` | Job tests | 40 |
| `test/models/chat_initiation_test.rb` | Chat tests | 20 |
| `test/models/agent_initiation_test.rb` | Agent tests | 25 |

**Total: ~290 lines of code** (down from 685)
