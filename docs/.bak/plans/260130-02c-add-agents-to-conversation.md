# Add Agents to Group Chat Conversation

## Executive Summary

Add the ability to invite additional agents into an existing group chat. A new "Add Agent" menu item appears in the "..." dropdown for group chats, opening a picker dialog to select an agent. On confirmation, the agent is added and a system message announces their arrival. The agent picker dialog is extracted as a shared component reused by both "Assign to Agent" and "Add Agent".

**Tech debt note:** The system message uses `role: "user"` with a `[System Notice]` prefix, consistent with `assign_agent`. This pattern should be revisited in favour of a proper system message mechanism, but that is out of scope here.

## Implementation Plan

### 1. Route

- [x] Add route in `config/routes.rb` inside the existing `member` block for chats:

```ruby
post :add_agent
```

### 2. Controller: `addable_agents` prop

- [x] In `ChatsController#show`, add `addable_agents` to the props:

```ruby
available_agents: available_agents,
addable_agents: addable_agents_for_chat,
```

- [x] Add private method. Uses the same `current_account.agents.active.as_json` serialization as `available_agents`, just filtered:

```ruby
def addable_agents_for_chat
  return [] unless @chat.group_chat?
  current_account.agents.active.where.not(id: @chat.agent_ids).as_json
end
```

### 3. Controller: `add_agent` action

- [x] Add to `ChatsController`:

```ruby
def add_agent
  unless @chat.group_chat?
    redirect_back_or_to account_chat_path(current_account, @chat),
      alert: "Can only add agents to group chats"
    return
  end

  agent = current_account.agents.find(params[:agent_id])

  if @chat.agents.include?(agent)
    redirect_back_or_to account_chat_path(current_account, @chat),
      alert: "#{agent.name} is already in this conversation"
    return
  end

  @chat.transaction do
    @chat.agents << agent
    @chat.messages.create!(
      role: "user",
      content: "[System Notice] #{agent.name} has joined the conversation."
    )
  end

  audit("add_agent_to_chat", @chat, agent_id: agent.id)
  redirect_to account_chat_path(current_account, @chat)
end
```

### 4. Extract `AgentPickerDialog` component

- [ ] Create `app/frontend/components/chat/AgentPickerDialog.svelte` (frontend - not in scope for backend task)

### 5. Frontend: Update `show.svelte`

- [ ] Frontend changes (not in scope for backend task)

### 6. Testing

- [x] Write controller tests in `test/controllers/chats_controller_test.rb`:
  - Adding an agent to a group chat succeeds and creates a system message
  - Adding an agent to a non-group chat is rejected
  - Adding a duplicate agent is rejected with a friendly message
  - The agent appears in `chat.agents` after adding

### 7. Regenerate JS routes

- [x] Ran `rails js:routes` to regenerate JS route helpers, confirmed `addAgentAccountChatPath` is available.

## Edge Cases

- **Duplicate agent**: Guard check before `@chat.agents << agent` returns a redirect with alert.
- **No addable agents**: Menu item hidden when `addable_agents` is empty (server-filtered).
- **Non-group chat**: Controller rejects with redirect and alert. Menu item only shown for `manual_responses` chats.
- **Agent from different account**: `current_account.agents.find` scopes to current account; foreign agents return 404.

## External Dependencies

None.
