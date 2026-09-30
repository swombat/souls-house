# Auto-Trigger Agents by Mention

## Executive Summary

When a human sends a message in a group chat and mentions agents by name, those agents are automatically triggered to respond sequentially -- like "Ask All" but only for the mentioned agents. This keeps the existing manual trigger system intact as a fallback for messages that don't mention anyone.

The implementation is surgical: one new method on `Chat`, three lines changed in `MessagesController#create`, and focused tests. No new files, no new jobs, no frontend changes.

## Architecture Overview

The feature follows existing patterns precisely:

1. **Mention detection and triggering** lives in a single `Chat` method (fat models, skinny controllers)
2. **Sequential triggering** reuses `AllAgentsResponseJob` which already handles ordered agent responses
3. **The controller** uses an explicit `if/else` to make the mutual exclusivity between single-agent auto-response and mention-triggered response obvious
4. **No frontend changes** -- the `AgentTriggerBar` continues to work for manual triggers

### Flow

```
Human sends message in group chat
  -> MessagesController#create saves message
  -> Controller branches: manual_responses? triggers mentions, else triggers AiResponseJob
  -> Chat#trigger_mentioned_agents! finds matching agents, enqueues AllAgentsResponseJob
  -> If none mentioned: no auto-trigger (existing behavior preserved)
```

## Implementation Plan

### Step 1: Add `trigger_mentioned_agents!` to Chat model

- [x] Add `Chat#trigger_mentioned_agents!(content)` method

One method that detects mentions and triggers the job. No private helpers, no separate detection method. The regex is simple enough to inline.

```ruby
def trigger_mentioned_agents!(content)
  return if content.blank? || !manual_responses?

  mentioned_ids = agents.select { |agent|
    content.match?(/\b#{Regexp.escape(agent.name)}\b/i)
  }.sort_by(&:id).map(&:id)

  AllAgentsResponseJob.perform_later(self, mentioned_ids) if mentioned_ids.any?
end
```

Key design decisions:

- **Single method**: No separate `agents_mentioned_in` -- it has exactly one caller. Extract it later if a second caller appears.
- **No `respondable?` guard**: The controller already enforces this via `before_action :require_respondable_chat`. Trust it.
- **Word boundary matching (`\b`)**: "Grok" matches in "Hey Grok, what do you think?" but not in "Groking the problem".
- **Case-insensitive (`/i`)**: "grok" matches agent named "Grok".
- **`Regexp.escape`**: Handles agent names with special regex characters safely (e.g. "C++Bot").
- **Sorted by `id`**: Consistent ordering for `AllAgentsResponseJob`, matching the pattern in `trigger_all_agents_response!`.
- **Loads agents via association**: Only matches agents actually in this chat. For a chat with 3-5 agents this is trivially cheap. No need for `pluck` micro-optimizations.
- **Reuses `AllAgentsResponseJob`**: No new job class. The job already handles sequential processing by running the first agent, then re-enqueuing itself with the remaining IDs.

### Step 2: Modify MessagesController#create

- [x] Replace the existing AI trigger line with an explicit `if/else`

Current code (line 28):

```ruby
AiResponseJob.perform_later(@chat) unless @chat.manual_responses?
```

Replace with:

```ruby
if @chat.manual_responses?
  @chat.trigger_mentioned_agents!(@message.content)
else
  AiResponseJob.perform_later(@chat)
end
```

The `if/else` reads like prose: "If it is a group chat, trigger mentioned agents; otherwise, trigger the AI response." No hidden guard clauses, no implicit mutual exclusion. The intent is on the surface. A reader encountering this for the first time understands immediately that exactly one of these paths fires.

### Step 3: Write model tests

- [x] Add 7 focused tests to `test/models/chat_test.rb`

Each test covers a distinct behavior.

```ruby
test "trigger_mentioned_agents! does nothing for non-group chat" do
  chat = Chat.create!(account: @account, model_id: "openrouter/auto")

  assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
    chat.trigger_mentioned_agents!("Hello Claude")
  end
end

test "trigger_mentioned_agents! does nothing for blank content" do
  agent = @account.agents.create!(name: "Claude", system_prompt: "Test")
  chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  chat.agent_ids = [agent.id]
  chat.save!

  assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
    chat.trigger_mentioned_agents!("")
    chat.trigger_mentioned_agents!(nil)
  end
end

test "trigger_mentioned_agents! enqueues job for mentioned agent" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  chat.agent_ids = [agent.id]
  chat.save!

  assert_enqueued_with(job: AllAgentsResponseJob, args: [chat, [agent.id]]) do
    chat.trigger_mentioned_agents!("Hey Grok, what do you think?")
  end
end

test "trigger_mentioned_agents! uses word boundaries" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  chat.agent_ids = [agent.id]
  chat.save!

  assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
    chat.trigger_mentioned_agents!("I'm groking this concept")
  end
end

test "trigger_mentioned_agents! detects multiple agents and excludes unmentioned" do
  agent1 = @account.agents.create!(name: "Grok", system_prompt: "Test")
  agent2 = @account.agents.create!(name: "Claude", system_prompt: "Test")
  agent3 = @account.agents.create!(name: "Wing", system_prompt: "Test")
  chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  chat.agent_ids = [agent1.id, agent2.id, agent3.id]
  chat.save!

  assert_enqueued_with(job: AllAgentsResponseJob) do
    chat.trigger_mentioned_agents!("Hey Grok and Claude, what do you think?")
  end

  job = enqueued_jobs.find { |j| j["job_class"] == "AllAgentsResponseJob" }
  mentioned_ids = job["arguments"].last
  assert_includes mentioned_ids, agent1.id
  assert_includes mentioned_ids, agent2.id
  assert_not_includes mentioned_ids, agent3.id
end

test "trigger_mentioned_agents! only matches agents in this chat" do
  agent_in_chat = @account.agents.create!(name: "Grok", system_prompt: "Test")
  @account.agents.create!(name: "Claude", system_prompt: "Test")
  chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  chat.agent_ids = [agent_in_chat.id]
  chat.save!

  assert_enqueued_with(job: AllAgentsResponseJob, args: [chat, [agent_in_chat.id]]) do
    chat.trigger_mentioned_agents!("Hey Grok and Claude")
  end
end

test "trigger_mentioned_agents! handles names with special regex characters" do
  agent = @account.agents.create!(name: "C++Bot", system_prompt: "Test")
  chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  chat.agent_ids = [agent.id]
  chat.save!

  assert_enqueued_with(job: AllAgentsResponseJob, args: [chat, [agent.id]]) do
    chat.trigger_mentioned_agents!("Hey C++Bot, help me")
  end
end
```

### Step 4: Write controller tests

- [x] Add 3 integration tests to `test/controllers/messages_controller_test.rb`

```ruby
test "should auto-trigger mentioned agents in group chat" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  group_chat.agent_ids = [agent.id]
  group_chat.save!

  assert_enqueued_with(job: AllAgentsResponseJob) do
    post account_chat_messages_path(@account, group_chat), params: {
      message: { content: "Hey Grok, what do you think?" }
    }
  end
end

test "should not auto-trigger when no agents mentioned in group chat" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  group_chat.agent_ids = [agent.id]
  group_chat.save!

  assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
    post account_chat_messages_path(@account, group_chat), params: {
      message: { content: "Hello everyone" }
    }
  end
end

test "should not enqueue AiResponseJob for group chat" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  group_chat.agent_ids = [agent.id]
  group_chat.save!

  assert_no_enqueued_jobs(only: AiResponseJob) do
    post account_chat_messages_path(@account, group_chat), params: {
      message: { content: "Hey Grok, what do you think?" }
    }
  end
end
```

## Edge Cases

**Agent not in the chat**: Handled naturally. `trigger_mentioned_agents!` iterates the chat's `agents` association, so it only matches agents that are participants. If someone types "Hey Claude" but Claude is not in the chat, nothing happens.

**Partial name matches**: Word boundary matching (`\b`) prevents "Grok" from matching "Groking".

**Multi-word agent names**: `\bResearch Assistant\b` matches correctly because `\b` checks for word boundaries at the start of "Research" and end of "Assistant".

**Agent names with special characters**: `Regexp.escape` handles names like "C++Bot". Word boundaries still anchor correctly around the escaped characters.

**Agent messages do not trigger**: Only `MessagesController#create` calls `trigger_mentioned_agents!`, and that action creates messages with `role: "user"`. Agent responses go through the job system and never hit this controller action.

**Multiple mentions of the same agent**: `agents.select` returns each agent at most once.

**Name that is a substring of another**: `\bChris\b` does not match inside "Christine" because there is no word boundary between "Chris" and "tine". The message "Chris and Christine" correctly matches only Chris (assuming both are agents in the chat).

## What This Does NOT Change

- No new database migrations
- No new jobs, controllers, or routes
- No frontend changes
- No changes to `AgentTriggerBar`, `AllAgentsResponseJob`, or `ManualAgentResponseJob`
- No changes to `create_with_message!`
- Manual trigger buttons continue to work exactly as before
- Single-agent chats continue to auto-respond via `AiResponseJob` as before

## Testing Strategy

1. **Model tests** (7 tests): Guard clauses, happy path, word boundaries, multiple agents, association scoping, special characters
2. **Controller tests** (3 tests): Auto-trigger fires, does not fire without mentions, `AiResponseJob` does not fire for group chats
3. **No new VCR cassettes needed**: All tests use job assertion helpers (`assert_enqueued_with`), not actual LLM calls
