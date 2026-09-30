# Per-Agent Thread Closing

## Problem

When multiple agents participate in a conversation, they create an infinite response loop. Agent A speaks, Agent B sees the conversation as "continuable" (someone else spoke last), so B responds. Then A sees B spoke last and responds again. The cycle repeats endlessly.

Agents recognize the thread should be closed but have no mechanism to mark it. The `continuable_conversations` query in `Agent::Initiation` only checks whether the agent spoke last — it has no concept of "this conversation is done."

## Executive Summary

Add per-agent conversation closing via a `closed_for_initiation_at` timestamp on `chat_agents`. Agents call a new `CloseConversationTool` to mark themselves done. Human messages auto-reopen all agents. This only affects self-initiation — manual triggers ("Ask Agent" button) still work.

## Architecture Overview

```
Agent initiation cycle:
    |
    v
continuable_conversations
    |
    +- Existing: exclude chats where I spoke last
    |
    +- NEW: exclude chats where I closed for initiation
    |
    v
Decision: continue | initiate | nothing

CloseConversationTool:
    Agent calls tool -> chat_agents.closed_for_initiation_at = now
    -> Agent stops seeing this chat in continuable_conversations

Human sends message:
    -> All chat_agents.closed_for_initiation_at reset to nil
    -> Agents can be prompted again
```

## Database Changes

One migration, one column on `chat_agents`:

```ruby
class AddClosedForInitiationToChatAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_agents, :closed_for_initiation_at, :datetime
    add_index :chat_agents, [:agent_id, :closed_for_initiation_at],
              name: "index_chat_agents_on_agent_closed_initiation"
  end
end
```

No changes to `chats` or `agents` tables.

## Implementation

### Phase 1: Database

- [ ] Create migration for `chat_agents` (`closed_for_initiation_at`)
- [ ] Run migration

### Phase 2: Model — ChatAgent

Add scopes and methods to `app/models/chat_agent.rb`:

```ruby
class ChatAgent < ApplicationRecord
  belongs_to :chat
  belongs_to :agent

  validates :agent_id, uniqueness: { scope: :chat_id }

  scope :closed_for_initiation, -> { where.not(closed_for_initiation_at: nil) }
  scope :open_for_initiation, -> { where(closed_for_initiation_at: nil) }

  def close_for_initiation!
    update!(closed_for_initiation_at: Time.current)
  end

  def reopen_for_initiation!
    update!(closed_for_initiation_at: nil)
  end
end
```

### Phase 3: Model — Agent::Initiation

Filter closed chats from `continuable_conversations` in `app/models/agent/initiation.rb`:

```ruby
def continuable_conversations
  chats.active.kept
       .where(manual_responses: true)
       .where.not(id: chats_where_i_spoke_last)
       .where.not(id: chats_closed_for_initiation)
       .order(updated_at: :desc)
       .limit(10)
end

private

def chats_closed_for_initiation
  ChatAgent.where(agent_id: id)
           .closed_for_initiation
           .pluck(:chat_id)
end
```

### Phase 4: Tool — CloseConversationTool

New file `app/tools/close_conversation_tool.rb`:

```ruby
class CloseConversationTool < RubyLLM::Tool
  description "Close this conversation for yourself. You won't be prompted to continue it " \
              "during initiation cycles. Other agents and humans can still interact. " \
              "Use when a conversation has naturally concluded."

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute
    return { error: "Only works in group conversations" } unless @current_agent && @chat

    chat_agent = ChatAgent.find_by(chat: @chat, agent: @current_agent)
    return { error: "Not a member of this conversation" } unless chat_agent

    chat_agent.close_for_initiation!
    { success: true, message: "Conversation closed for initiation." }
  end
end
```

### Phase 5: Auto-Reopen on Human Message

Add callback in `app/models/message.rb`:

```ruby
after_create :reopen_conversation_for_agents, if: :human_message_in_group_chat?

private

def human_message_in_group_chat?
  role == "user" && user_id.present? && chat.manual_responses?
end

def reopen_conversation_for_agents
  chat.chat_agents.closed_for_initiation.update_all(closed_for_initiation_at: nil)
end
```

### Phase 6: Testing

- [ ] ChatAgent close/reopen unit tests
- [ ] Agent::Initiation filtering of closed conversations
- [ ] CloseConversationTool unit tests
- [ ] Message auto-reopen callback tests

## File Summary

| File | Change |
|------|--------|
| `db/migrate/TIMESTAMP_add_closed_for_initiation_to_chat_agents.rb` | **NEW** — add column |
| `app/models/chat_agent.rb` | Add scopes and close/reopen methods |
| `app/models/agent/initiation.rb` | Filter closed chats from `continuable_conversations` |
| `app/tools/close_conversation_tool.rb` | **NEW** — tool for agents to close conversations |
| `app/models/message.rb` | Add `after_create` callback for auto-reopen |
| `test/models/chat_agent_test.rb` | **NEW** — close/reopen tests |
| `test/models/agent_initiation_test.rb` | Additional tests for closed filtering |
| `test/tools/close_conversation_tool_test.rb` | **NEW** — tool tests |

## Key Design Decisions

1. **Per-agent, not per-chat** — Each agent independently decides "I'm done." One agent closing doesn't affect others.
2. **Timestamp, not boolean** — `closed_for_initiation_at` allows future features like "closed N hours ago" decay.
3. **Auto-reopen on human message** — Simple, predictable behavior. Humans don't need a UI to reopen.
4. **Manual triggers unaffected** — Closing only affects self-initiation cycles, not the "Ask Agent" button.
5. **No UI changes** — Agents close via the tool, humans reopen by messaging. UI controls can come later.
