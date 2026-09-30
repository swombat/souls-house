# Add Agents to Group Chat Conversation

## Executive Summary

Add the ability to invite additional agents into an existing group chat. A new "Add Agent" menu item appears in the "..." dropdown for group chats, opening a dialog to select an agent. On confirmation, the agent is added to the chat and a system message announces their arrival.

## Architecture Overview

This follows the exact pattern of `assign_agent` but is simpler: no mode conversion needed, just append an agent to an existing group chat. The frontend reuses the same Dialog + Select pattern already used for "Assign to Agent".

## Implementation Plan

### 1. Route

- [ ] Add route to `config/routes.rb` inside the existing `member` block for chats:

```ruby
post :add_agent
```

This generates `add_agent_account_chat_path(account_id, chat_id)`.

### 2. Controller Action

- [ ] Add `add_agent` action to `ChatsController`:

```ruby
def add_agent
  unless @chat.group_chat?
    redirect_back_or_to account_chat_path(current_account, @chat),
      alert: "Can only add agents to group chats"
    return
  end

  agent = current_account.agents.find(params[:agent_id])

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

The `ChatAgent` model already has a uniqueness validation on `[chat_id, agent_id]`, so adding a duplicate will raise `ActiveRecord::RecordInvalid`. We let that bubble up naturally (Rails will render a 422). Alternatively, we can add a guard:

```ruby
if @chat.agents.include?(agent)
  redirect_back_or_to account_chat_path(current_account, @chat),
    alert: "#{agent.name} is already in this conversation"
  return
end
```

The guard approach is preferred for a better user experience.

### 3. Regenerate JS Routes

- [ ] Run `rails generate js_routes` (or whatever the project uses) to regenerate route helpers so `addAgentAccountChatPath` becomes available in `app/frontend/routes/index.js`.

### 4. Frontend Changes in `app/frontend/pages/chats/show.svelte`

- [ ] Import the new route helper:

```js
import {
  // ... existing imports
  addAgentAccountChatPath,
} from '@/routes';
```

- [ ] Add state variables for the "Add Agent" dialog:

```js
let addAgentOpen = $state(false);
let addAgentSelectedId = $state(null);
let addingAgent = $state(false);
```

- [ ] Compute agents not yet in the chat (available to add):

```js
const addableAgents = $derived(
  available_agents.filter((a) => !agents.some((existing) => existing.id === a.id))
);
```

- [ ] Add the `addAgentToChat` function:

```js
function addAgentToChat() {
  if (!chat || !addAgentSelectedId) return;
  addingAgent = true;
  router.post(
    addAgentAccountChatPath(account.id, chat.id),
    { agent_id: addAgentSelectedId },
    {
      onFinish: () => {
        addingAgent = false;
        addAgentOpen = false;
        addAgentSelectedId = null;
      },
    }
  );
}
```

- [ ] Add the "Add Agent" menu item in the dropdown. Insert it inside the `{#if chat.manual_responses}` block (which currently does not exist as a visible block -- the existing code only shows items when `!chat.manual_responses`). Add a new block right after line 1161 (`{/if}`):

```svelte
{#if chat.manual_responses && addableAgents.length > 0}
  <DropdownMenu.Item onclick={() => (addAgentOpen = true)}>
    <Robot size={16} class="mr-2" weight="duotone" />
    Add Agent
  </DropdownMenu.Item>
{/if}
```

- [ ] Add the "Add Agent" dialog at the bottom of the file (near the existing "Assign Agent" dialog):

```svelte
<Dialog.Root bind:open={addAgentOpen}>
  <Dialog.Content class="max-w-md">
    <Dialog.Header>
      <Dialog.Title>Add Agent to Conversation</Dialog.Title>
      <Dialog.Description>
        Select an agent to add to this group chat.
      </Dialog.Description>
    </Dialog.Header>

    <div class="py-4">
      <Select.Root type="single" value={addAgentSelectedId} onValueChange={(value) => (addAgentSelectedId = value)}>
        <Select.Trigger class="w-full">
          {#if addAgentSelectedId}
            {addableAgents.find((a) => a.id === addAgentSelectedId)?.name ?? 'Select an agent'}
          {:else}
            Select an agent
          {/if}
        </Select.Trigger>
        <Select.Content sideOffset={4} class="max-h-60">
          {#each addableAgents as agent (agent.id)}
            <Select.Item value={agent.id} label={agent.name}>
              <span class="flex items-center gap-2">
                <Robot size={14} weight="duotone" />
                {agent.name}
              </span>
            </Select.Item>
          {/each}
        </Select.Content>
      </Select.Root>
    </div>

    <Dialog.Footer>
      <Button variant="outline" onclick={() => (addAgentOpen = false)}>Cancel</Button>
      <Button onclick={addAgentToChat} disabled={!addAgentSelectedId || addingAgent}>
        {#if addingAgent}
          <Spinner size={16} class="mr-2 animate-spin" />
          Adding...
        {:else}
          Add
        {/if}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
```

### 5. Testing

- [ ] Write a controller test in `test/controllers/chats_controller_test.rb`:
  - Test adding an agent to a group chat succeeds
  - Test adding an agent to a non-group chat is rejected
  - Test adding a duplicate agent is rejected with a friendly message
  - Test a system message is created after adding an agent
  - Test the agent appears in `chat.agents` after adding

## Edge Cases

- **Duplicate agent**: Handled by the guard check before `@chat.agents << agent`.
- **No available agents**: The menu item is hidden when `addableAgents.length === 0`.
- **Non-group chat**: Controller rejects with redirect and alert.
- **Agent from different account**: `current_account.agents.find(params[:agent_id])` scopes to current account, so foreign agents return 404.

## External Dependencies

None. This uses existing UI components (Dialog, Select, DropdownMenu) and follows established patterns exactly.
