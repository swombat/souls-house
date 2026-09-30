# Add Agents to Group Chat Conversation

## Executive Summary

Add the ability to invite additional agents into an existing group chat. A new "Add Agent" menu item appears in the "..." dropdown for group chats, opening a picker dialog to select an agent. On confirmation, the agent is added and a system message announces their arrival. The agent picker dialog is extracted as a shared component since the "Assign to Agent" dialog uses the same pattern.

## Architecture Overview

This follows the `assign_agent` pattern: a new controller action, a route, and a frontend dialog. The key difference from v1: the server provides `addable_agents` as a prop (agents not yet in the chat), an `AgentPickerDialog` component is extracted to eliminate duplication, and Inertia's built-in `processing` state replaces manual loading tracking.

**Tech debt note:** The system message uses `role: "user"` with a `[System Notice]` prefix, consistent with `assign_agent`. This pattern should be revisited in favour of a proper system message mechanism, but that is out of scope here.

## Implementation Plan

### 1. Route

- [ ] Add route in `config/routes.rb` inside the existing `member` block for chats:

```ruby
post :add_agent
```

### 2. Controller: `addable_agents` prop

- [ ] In `ChatsController#show`, add `addable_agents` to the props for group chats. This filters out agents already in the chat, keeping the frontend dumb:

```ruby
# In the show action props hash, replace available_agents with:
available_agents: available_agents,
addable_agents: addable_agents_for_chat,
```

- [ ] Add private method:

```ruby
def addable_agents_for_chat
  return [] unless @chat.group_chat?
  current_account.agents.active.where.not(id: @chat.agent_ids).as_json
end
```

### 3. Controller: `add_agent` action

- [ ] Add to `ChatsController`:

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

- [ ] Create `app/frontend/components/chat/AgentPickerDialog.svelte`:

```svelte
<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Robot, Spinner } from 'phosphor-svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';

  let {
    open = $bindable(false),
    agents = [],
    title = 'Select Agent',
    description = '',
    confirmLabel = 'Confirm',
    confirmingLabel = 'Confirming...',
    processing = false,
    onconfirm,
  } = $props();

  let selectedAgentId = $state(null);

  function handleConfirm() {
    if (!selectedAgentId) return;
    onconfirm?.(selectedAgentId);
  }

  $effect(() => {
    if (!open) selectedAgentId = null;
  });
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="max-w-md">
    <Dialog.Header>
      <Dialog.Title>{title}</Dialog.Title>
      {#if description}
        <Dialog.Description>{description}</Dialog.Description>
      {/if}
    </Dialog.Header>

    <div class="py-4">
      <Select.Root type="single" value={selectedAgentId} onValueChange={(value) => (selectedAgentId = value)}>
        <Select.Trigger class="w-full">
          {#if selectedAgentId}
            {agents.find((a) => a.id === selectedAgentId)?.name ?? 'Select an agent'}
          {:else}
            Select an agent
          {/if}
        </Select.Trigger>
        <Select.Content sideOffset={4} class="max-h-60">
          {#each agents as agent (agent.id)}
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
      <Button variant="outline" onclick={() => (open = false)}>Cancel</Button>
      <Button onclick={handleConfirm} disabled={!selectedAgentId || processing}>
        {#if processing}
          <Spinner size={16} class="mr-2 animate-spin" />
          {confirmingLabel}
        {:else}
          {confirmLabel}
        {/if}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
```

### 5. Frontend: Update `show.svelte`

- [ ] Add `addable_agents` to destructured props:

```js
let {
  // ... existing props
  addable_agents = [],
} = $props();
```

- [ ] Import the new route helper and component:

```js
import { addAgentAccountChatPath } from '@/routes';
import AgentPickerDialog from '$lib/components/chat/AgentPickerDialog.svelte';
```

- [ ] Add dialog state (two variables, not three -- no manual loading state):

```js
let addAgentOpen = $state(false);
let addAgentProcessing = $state(false);
```

- [ ] Add the `addAgentToChat` handler:

```js
function addAgentToChat(agentId) {
  if (!chat) return;
  addAgentProcessing = true;
  router.post(
    addAgentAccountChatPath(account.id, chat.id),
    { agent_id: agentId },
    {
      onFinish: () => {
        addAgentProcessing = false;
        addAgentOpen = false;
      },
    }
  );
}
```

- [ ] Add the "Add Agent" menu item in the dropdown, right after the `{/if}` closing the `{#if !chat.manual_responses}` block (line 1161):

```svelte
{#if chat.manual_responses && addable_agents.length > 0}
  <DropdownMenu.Item onclick={() => (addAgentOpen = true)}>
    <Robot size={16} class="mr-2" weight="duotone" />
    Add Agent
  </DropdownMenu.Item>
{/if}
```

- [ ] Replace the existing "Assign Agent" dialog markup with `AgentPickerDialog`:

```svelte
<AgentPickerDialog
  bind:open={assignAgentOpen}
  agents={available_agents}
  title="Assign to Agent"
  description="Select an agent to take over this conversation. The agent will be informed that previous messages were with a model that had no identity or memories."
  confirmLabel="Assign"
  confirmingLabel="Assigning..."
  processing={assigningAgent}
  onconfirm={(agentId) => { selectedAgentId = agentId; assignToAgent(); }}
/>
```

- [ ] Add the "Add Agent" dialog instance:

```svelte
<AgentPickerDialog
  bind:open={addAgentOpen}
  agents={addable_agents}
  title="Add Agent to Conversation"
  description="Select an agent to add to this group chat."
  confirmLabel="Add"
  confirmingLabel="Adding..."
  processing={addAgentProcessing}
  onconfirm={addAgentToChat}
/>
```

- [ ] Clean up: the `assignToAgent` function can be simplified since the dialog now passes the agent ID directly. Update it to accept an `agentId` parameter or keep `selectedAgentId` as-is for the callback.

### 6. Testing

- [ ] Write controller tests in `test/controllers/chats_controller_test.rb`:
  - Adding an agent to a group chat succeeds and creates a system message
  - Adding an agent to a non-group chat is rejected
  - Adding a duplicate agent is rejected with a friendly message
  - The agent appears in `chat.agents` after adding
  - `addable_agents` prop excludes agents already in the chat

## Edge Cases

- **Duplicate agent**: Guard check before `@chat.agents << agent` returns a redirect with alert.
- **No addable agents**: Menu item hidden when `addable_agents` is empty (server-filtered).
- **Non-group chat**: Controller rejects with redirect and alert. Menu item only shown for `manual_responses` chats.
- **Agent from different account**: `current_account.agents.find` scopes to current account; foreign agents return 404.

## External Dependencies

None.
