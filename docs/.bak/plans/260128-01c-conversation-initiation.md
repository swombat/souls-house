# Conversation Initiation Feature

## Executive Summary

Agents can proactively initiate or continue conversations with users. An hourly job during daytime hours (9am-9pm GMT) evaluates each agent in active accounts using a single LLM call with structured JSON output.

## Architecture Overview

```
ConversationInitiationJob (hourly, 9am-9pm GMT)
    |
    v
For each eligible agent:
    |
    +- Skip if at_initiation_cap?
    |
    +- Build initiation prompt (model method)
    |
    +- Single LLM call -> JSON response
    |
    +- Execute decision: continue | initiate | nothing
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

## Implementation Checklist

### Phase 1: Database
- [x] Create migration for `chats` (initiated_by_agent_id, initiation_reason)
- [x] Run migration

### Phase 2: Models
- [x] Add `belongs_to :initiated_by_agent` to Chat
- [x] Add scopes `initiated` and `awaiting_human_response` to Chat
- [x] Add `Chat.initiate_by_agent!` class method
- [x] Add initiation methods to Agent (`at_initiation_cap?`, `continuable_conversations`, etc.)
- [x] Add `build_initiation_prompt` to Agent
- [x] Include `ActionView::Helpers::DateHelper` in Agent

### Phase 3: Job
- [x] Create ConversationInitiationJob
- [x] Add to config/recurring.yml

### Phase 4: Testing
- [x] Unit tests for Chat initiation (9 tests)
- [x] Unit tests for Agent initiation methods (21 tests)
- [x] Job tests with mocked LLM (12 tests)

## File Summary

| File | Purpose | Status |
|------|---------|--------|
| `db/migrate/20260128074332_add_initiation_to_chats.rb` | Schema changes | Complete |
| `app/models/chat.rb` | Add scopes and `initiate_by_agent!` | Complete |
| `app/models/agent.rb` | Add initiation methods | Complete |
| `app/jobs/conversation_initiation_job.rb` | Hourly job | Complete |
| `config/recurring.yml` | Schedule | Complete |
| `test/models/chat_initiation_test.rb` | Chat tests | Complete |
| `test/models/agent_initiation_test.rb` | Agent tests | Complete |
| `test/jobs/conversation_initiation_job_test.rb` | Job tests | Complete |

## Test Results

All 41 new tests pass:
- ChatInitiationTest: 9 tests
- AgentInitiationTest: 21 tests
- ConversationInitiationJobTest: 12 tests

Total: 119 related tests pass (including existing Chat and Agent tests)
