# Auto-Trigger Agents by Mention

## Executive Summary

When a human sends a message in a group chat and mentions agents by name, those agents should be automatically triggered to respond sequentially -- like "Ask All" but only for the mentioned agents. This keeps the existing manual trigger system intact as a fallback for messages that don't mention anyone.

The implementation is surgical: one new method on `Chat`, one modified line in `MessagesController#create`, and thorough tests. No new files, no new jobs, no frontend changes.

## Architecture Overview

The feature follows the existing patterns precisely:

1. **Mention detection** lives in the `Chat` model as business logic (fat models, skinny controllers)
2. **Sequential triggering** reuses the existing `AllAgentsResponseJob` which already handles ordered agent responses
3. **The controller** gains a single conditional line after message save
4. **No frontend changes** -- the `AgentTriggerBar` continues to work for manual triggers

### Flow

```
Human sends message in group chat
  -> MessagesController#create saves message
  -> Chat#mentioned_agent_ids(message.content) returns matching agent IDs
  -> If any found: AllAgentsResponseJob.perform_later(chat, mentioned_agent_ids)
  -> If none found: no auto-trigger (existing behavior preserved)
```

## Implementation Plan

### Step 1: Add mention detection to Chat model

- [ ] Add `Chat#agents_mentioned_in(content)` method

This method takes a message content string and returns an ordered array of agent IDs for agents whose names appear in the text. It uses word boundary matching to avoid false positives.

```ruby
class Chat < ApplicationRecord

  def agents_mentioned_in(content)
    return [] if content.blank? || !manual_responses?

    mentioned = agents.select do |agent|
      name_pattern = agent_name_pattern(agent.name)
      content.match?(name_pattern)
    end

    mentioned.sort_by(&:id).map(&:id)
  end

  private

  def agent_name_pattern(name)
    escaped = Regexp.escape(name)
    /\b#{escaped}\b/i
  end

end
```

Key design decisions:

- **Word boundary matching (`\b`)**: "Grok" matches in "Hey Grok, what do you think?" but not in "Groking the problem". This handles both single-word names (Grok, Claude) and multi-word names (Research Assistant) correctly since `\b` respects word boundaries at the start and end of multi-word strings.
- **Case-insensitive (`/i`)**: "grok" matches agent named "Grok".
- **Returns IDs sorted by `id`**: Consistent ordering for `AllAgentsResponseJob`, matching the pattern used in `trigger_all_agents_response!`.
- **Guards on `manual_responses?`**: Only group chats support this feature.
- **`Regexp.escape`**: Handles agent names with special regex characters safely.
- **Loads agents via association**: Only matches agents actually in this chat, not all agents in the account.

### Step 2: Add auto-trigger method to Chat model

- [ ] Add `Chat#auto_trigger_mentioned_agents!(content)` method

This method encapsulates the full "detect and trigger" logic, keeping the controller thin.

```ruby
class Chat < ApplicationRecord

  def auto_trigger_mentioned_agents!(content)
    return unless manual_responses? && respondable?

    mentioned_ids = agents_mentioned_in(content)
    return if mentioned_ids.empty?

    AllAgentsResponseJob.perform_later(self, mentioned_ids)
  end

end
```

This reuses `AllAgentsResponseJob` directly -- no new job class needed. The job already handles sequential processing by running the first agent, then re-enqueuing itself with the remaining IDs.

### Step 3: Modify MessagesController#create

- [ ] Add one line after message save to trigger mentioned agents

```ruby
def create
  @message = @chat.messages.build(
    message_params.merge(user: Current.user, role: "user")
  )
  @message.attachments.attach(params[:files]) if params[:files].present?

  if @message.save
    audit("create_message", @message, **message_params.to_h)
    AiResponseJob.perform_later(@chat) unless @chat.manual_responses?
    @chat.auto_trigger_mentioned_agents!(@message.content)

    respond_to do |format|
      # ... existing response handling
    end
  end
end
```

The new line sits naturally alongside the existing `AiResponseJob` line. The two are mutually exclusive by design:

- Single-agent chats (`manual_responses? == false`): `AiResponseJob` fires, `auto_trigger_mentioned_agents!` returns immediately (guards on `manual_responses?`).
- Group chats (`manual_responses? == true`): `AiResponseJob` is skipped, `auto_trigger_mentioned_agents!` runs and may trigger agents.

### Step 4: Handle auto-trigger for Chat.create_with_message!

- [ ] Add auto-trigger to `create_with_message!` for group chats created with an initial message

The `create_with_message!` class method also creates messages and triggers AI responses. It needs the same treatment:

```ruby
def self.create_with_message!(attributes, message_content: nil, user: nil, files: nil, agent_ids: nil)
  transaction do
    chat = new(attributes)
    chat.agent_ids = agent_ids if agent_ids.present?
    chat.save!

    if message_content.present? || (files.present? && files.any?)
      message = chat.messages.create!({
        content: message_content || "",
        role: "user",
        user: user,
        skip_content_validation: message_content.blank? && files.present? && files.any?
      })
      message.attachments.attach(files) if files.present? && files.any?

      AiResponseJob.perform_later(chat) unless chat.manual_responses?
      chat.auto_trigger_mentioned_agents!(message_content)
    end
    chat
  end
end
```

In practice, group chats created via `create_with_message!` with an initial message mentioning agents will auto-trigger those agents. This is unlikely but worth handling for consistency.

### Step 5: Write model tests for mention detection

- [ ] Add tests to `test/models/chat_test.rb`

```ruby
# Mention detection tests

test "agents_mentioned_in returns empty for non-group chat" do
  chat = Chat.create!(account: @account, model_id: "openrouter/auto")
  assert_equal [], chat.agents_mentioned_in("Hello Claude")
end

test "agents_mentioned_in returns empty for blank content" do
  agent = @account.agents.create!(name: "Claude", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  assert_equal [], chat.agents_mentioned_in("")
  assert_equal [], chat.agents_mentioned_in(nil)
end

test "agents_mentioned_in detects single agent mention" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  assert_equal [agent.id], chat.agents_mentioned_in("Hey Grok, what do you think?")
end

test "agents_mentioned_in is case insensitive" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  assert_equal [agent.id], chat.agents_mentioned_in("hey grok, what do you think?")
  assert_equal [agent.id], chat.agents_mentioned_in("GROK please respond")
end

test "agents_mentioned_in uses word boundaries" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  assert_equal [], chat.agents_mentioned_in("I'm groking this concept")
  assert_equal [agent.id], chat.agents_mentioned_in("Grok, help me")
end

test "agents_mentioned_in detects multiple agents" do
  agent1 = @account.agents.create!(name: "Grok", system_prompt: "Test")
  agent2 = @account.agents.create!(name: "Claude", system_prompt: "Test")
  agent3 = @account.agents.create!(name: "Wing", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent1.id, agent2.id, agent3.id])

  result = chat.agents_mentioned_in("Hey Grok and Claude, what do you think?")
  assert_includes result, agent1.id
  assert_includes result, agent2.id
  assert_not_includes result, agent3.id
end

test "agents_mentioned_in returns IDs sorted by id" do
  agent1 = @account.agents.create!(name: "Zara", system_prompt: "Test")
  agent2 = @account.agents.create!(name: "Alpha", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent1.id, agent2.id])

  result = chat.agents_mentioned_in("Hey Alpha and Zara")
  assert_equal result, result.sort
end

test "agents_mentioned_in handles multi-word agent names" do
  agent = @account.agents.create!(name: "Research Assistant", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  assert_equal [agent.id], chat.agents_mentioned_in("Hey Research Assistant, look into this")
end

test "agents_mentioned_in only matches agents in this chat" do
  agent_in_chat = @account.agents.create!(name: "Grok", system_prompt: "Test")
  @account.agents.create!(name: "Claude", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent_in_chat.id])

  result = chat.agents_mentioned_in("Hey Grok and Claude")
  assert_equal [agent_in_chat.id], result
end

test "agents_mentioned_in handles names with special regex characters" do
  agent = @account.agents.create!(name: "C++Bot", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  assert_equal [agent.id], chat.agents_mentioned_in("Hey C++Bot, help me")
end

test "agents_mentioned_in handles agent name at start of message" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  assert_equal [agent.id], chat.agents_mentioned_in("Grok what do you think?")
end

test "agents_mentioned_in handles agent name at end of message" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  assert_equal [agent.id], chat.agents_mentioned_in("What do you think Grok")
end
```

### Step 6: Write model tests for auto-trigger

- [ ] Add tests to `test/models/chat_test.rb`

```ruby
test "auto_trigger_mentioned_agents! enqueues job for mentioned agents" do
  agent1 = @account.agents.create!(name: "Grok", system_prompt: "Test")
  agent2 = @account.agents.create!(name: "Claude", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent1.id, agent2.id])

  assert_enqueued_with(job: AllAgentsResponseJob, args: [chat, [agent1.id]]) do
    chat.auto_trigger_mentioned_agents!("Hey Grok, what do you think?")
  end
end

test "auto_trigger_mentioned_agents! does nothing when no agents mentioned" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])

  assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
    chat.auto_trigger_mentioned_agents!("Hello everyone")
  end
end

test "auto_trigger_mentioned_agents! does nothing for non-group chats" do
  chat = Chat.create!(account: @account, model_id: "openrouter/auto")

  assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
    chat.auto_trigger_mentioned_agents!("Hey Grok")
  end
end

test "auto_trigger_mentioned_agents! does nothing for archived chats" do
  agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
  chat = create_group_chat(agent_ids: [agent.id])
  chat.archive!

  assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
    chat.auto_trigger_mentioned_agents!("Hey Grok")
  end
end
```

### Step 7: Write controller tests

- [ ] Add tests to `test/controllers/messages_controller_test.rb`

```ruby
test "should auto-trigger mentioned agents in group chat" do
  Setting.instance.update!(allow_chats: true)
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
  Setting.instance.update!(allow_chats: true)
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

test "should not auto-trigger AiResponseJob for group chat" do
  Setting.instance.update!(allow_chats: true)
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

### Step 8: Add test helper for group chat creation

- [ ] Add `create_group_chat` helper to `ChatTest`

```ruby
private

def create_group_chat(agent_ids:)
  chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
  chat.agent_ids = agent_ids
  chat.save!
  chat
end
```

## Edge Cases

### Agent not in the chat
Handled naturally. `agents_mentioned_in` iterates over `agents` (the chat's agents association), so it only matches agents that are participants in this specific chat. If someone types "Hey Claude" but Claude isn't in the chat, nothing happens.

### Partial name matches
Word boundary matching (`\b`) prevents "Grok" from matching "Groking". The regex `\bGrok\b` requires word boundaries on both sides.

### Multi-word agent names
Word boundaries work correctly with multi-word names. `\bResearch Assistant\b` matches "Hey Research Assistant, look into this" because `\b` checks for word boundaries at the start of "Research" and end of "Assistant".

### Agent names with special characters
`Regexp.escape` handles agent names containing regex-special characters like `+`, `.`, `(`, etc. "C++Bot" becomes `\bC\+\+Bot\b`.

### Agent messages do not trigger
Only `MessagesController#create` calls `auto_trigger_mentioned_agents!`, and that action always creates messages with `role: "user"` and `user: Current.user`. Agent responses go through the job system and never hit this controller action.

### Multiple mentions of the same agent
`agents.select` returns each agent at most once (it iterates the association), so mentioning "Grok, hey Grok, GROK" still only triggers Grok once.

### Empty or nil content
Guarded at the top of `agents_mentioned_in` with `return [] if content.blank?`.

### Non-respondable chats
Guarded in `auto_trigger_mentioned_agents!` with `return unless respondable?`.

### Name that is a substring of another name
If the chat has agents named "Chris" and "Christine", the word boundary matching prevents "Christine" from also matching "Chris" -- `\bChris\b` would not match inside "Christine" because there's no word boundary between "Chris" and "tine". However, the message "Chris and Christine" would correctly match both.

## What This Does NOT Change

- No new database migrations
- No new jobs
- No new controllers or routes
- No frontend changes
- No changes to the `AgentTriggerBar` component
- No changes to `AllAgentsResponseJob` or `ManualAgentResponseJob`
- No changes to the API endpoints
- The manual trigger buttons continue to work exactly as before
- Single-agent chats continue to auto-respond via `AiResponseJob` as before

## Testing Strategy

1. **Unit tests** (Chat model): Test `agents_mentioned_in` with various inputs -- case sensitivity, word boundaries, multi-word names, special characters, empty input, non-group chats
2. **Unit tests** (Chat model): Test `auto_trigger_mentioned_agents!` with job assertion helpers
3. **Integration tests** (MessagesController): Test that creating a message in a group chat with mentions enqueues the right job
4. **No new VCR cassettes needed**: All tests use job assertion helpers (`assert_enqueued_with`), not actual LLM calls
