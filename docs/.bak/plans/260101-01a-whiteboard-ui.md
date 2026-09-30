# Whiteboard UI Implementation Specification

## Overview

This specification details the implementation of a human-friendly UI for viewing and editing whiteboards. The feature consists of three main parts:

1. **Whiteboard Pane in Chat** - A slide-up drawer showing the active whiteboard with view/edit capabilities
2. **Navbar Dropdown** - Converting "Agents" to a dropdown with "Identities" and "Whiteboards" options
3. **Whiteboards Index Page** - A standalone page listing all whiteboards with inline viewing/editing

## Architecture

### Key Components

```
WhiteboardViewer.svelte (reusable)
├── View mode: Rendered markdown
├── Edit mode: Textarea with save button
├── Real-time sync via useSync
└── Conflict warning for external changes

ChatWhiteboardPane.svelte (chat-specific wrapper)
├── Uses ShadcnUI Drawer component
├── Slides up from bottom
└── Wraps WhiteboardViewer

pages/whiteboards/index.svelte (standalone page)
├── List of all whiteboards
└── Inline WhiteboardViewer on selection
```

### Data Flow

```
Chat (has active_whiteboard)
    │
    ▼
WhiteboardViewer ◄─── useSync ◄─── Whiteboard broadcasts
    │
    ▼
PATCH /accounts/:id/whiteboards/:id (on save)
```

---

## Backend Changes

### Step 1: Add Whiteboards Controller

- [ ] Create `WhiteboardsController` with index, show, and update actions

**File:** `app/controllers/whiteboards_controller.rb`

```ruby
class WhiteboardsController < ApplicationController

  require_feature_enabled :agents  # Whiteboards are part of agents feature
  before_action :set_whiteboard, only: [:show, :update]

  def index
    @whiteboards = current_account.whiteboards.active.by_name

    render inertia: "whiteboards/index", props: {
      whiteboards: whiteboards_json(@whiteboards),
      account: current_account.as_json
    }
  end

  def show
    render inertia: "whiteboards/show", props: {
      whiteboard: whiteboard_json(@whiteboard),
      account: current_account.as_json
    }
  end

  def update
    if @whiteboard.update(whiteboard_params.merge(last_edited_by: Current.user))
      head :ok
    else
      render json: { errors: @whiteboard.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def set_whiteboard
    @whiteboard = current_account.whiteboards.active.find(params[:id])
  end

  def whiteboard_params
    params.require(:whiteboard).permit(:content)
  end

  def whiteboards_json(whiteboards)
    whiteboards.map { |w| whiteboard_json(w) }
  end

  def whiteboard_json(whiteboard)
    {
      id: whiteboard.id,
      name: whiteboard.name,
      summary: whiteboard.summary,
      content: whiteboard.content,
      content_length: whiteboard.content.to_s.length,
      revision: whiteboard.revision,
      last_edited_at: whiteboard.last_edited_at&.strftime("%b %d at %l:%M %p"),
      editor_name: whiteboard.editor_name,
      active_chat_count: Chat.where(active_whiteboard_id: whiteboard.id).count
    }
  end

end
```

### Step 2: Add Routes

- [ ] Add whiteboard routes under accounts

**File:** `config/routes.rb`

Add within the `resources :accounts` block:

```ruby
resources :whiteboards, only: [:index, :show, :update]
```

### Step 3: Update Chat Controller to Include Active Whiteboard

- [ ] Pass active_whiteboard data to chat show page

**File:** `app/controllers/chats_controller.rb`

Update the `show` action to include whiteboard data:

```ruby
def show
  @chats = current_account.chats.latest
  @messages = @chat.messages.includes(:user, :agent).with_attached_attachments.sorted

  render inertia: "chats/show", props: {
    chat: chat_with_whiteboard_json,
    chats: @chats.as_json,
    messages: @messages.all.collect(&:as_json),
    account: current_account.as_json,
    models: available_models,
    agents: @chat.group_chat? ? @chat.agents.as_json : [],
    file_upload_config: file_upload_config
  }
end

private

def chat_with_whiteboard_json
  json = @chat.as_json
  if @chat.active_whiteboard && !@chat.active_whiteboard.deleted?
    json[:active_whiteboard] = {
      id: @chat.active_whiteboard.id,
      name: @chat.active_whiteboard.name,
      content: @chat.active_whiteboard.content,
      revision: @chat.active_whiteboard.revision,
      last_edited_at: @chat.active_whiteboard.last_edited_at&.strftime("%b %d at %l:%M %p"),
      editor_name: @chat.active_whiteboard.editor_name
    }
  end
  json
end
```

### Step 4: Ensure Whiteboard Broadcasts Properly

- [ ] Verify Whiteboard includes Broadcastable (already done)
- [ ] Verify broadcasts_to :account (already done)

The `Whiteboard` model already includes these. No changes needed.

---

## Frontend Implementation

### Step 5: Create WhiteboardViewer Component

- [ ] Create reusable WhiteboardViewer component

**File:** `app/frontend/lib/components/whiteboard/WhiteboardViewer.svelte`

```svelte
<script>
  import { useForm, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { PencilSimple, FloppyDisk, X, WarningCircle } from 'phosphor-svelte';
  import { Streamdown } from 'svelte-streamdown';

  let {
    whiteboard,
    accountId,
    agentIsResponding = false,
    onSave = null,
    class: className = '',
  } = $props();

  let isEditing = $state(false);
  let editContent = $state('');
  let originalRevision = $state(null);
  let hasExternalChanges = $state(false);

  // Track when content changes externally while editing
  $effect(() => {
    if (isEditing && whiteboard?.revision !== originalRevision) {
      hasExternalChanges = true;
    }
  });

  function startEditing() {
    editContent = whiteboard?.content || '';
    originalRevision = whiteboard?.revision;
    hasExternalChanges = false;
    isEditing = true;
  }

  function cancelEditing() {
    isEditing = false;
    editContent = '';
    hasExternalChanges = false;
  }

  function saveContent() {
    router.patch(
      `/accounts/${accountId}/whiteboards/${whiteboard.id}`,
      { whiteboard: { content: editContent } },
      {
        preserveScroll: true,
        onSuccess: () => {
          isEditing = false;
          hasExternalChanges = false;
          if (onSave) onSave();
        },
      }
    );
  }

  const editDisabled = $derived(agentIsResponding);
  const editDisabledReason = $derived(
    agentIsResponding ? 'Agent is updating whiteboard...' : null
  );
</script>

<div class="flex flex-col h-full {className}">
  <!-- Header -->
  <div class="flex items-center justify-between px-4 py-3 border-b border-border">
    <div>
      <h3 class="font-semibold text-lg">{whiteboard?.name || 'Whiteboard'}</h3>
      {#if whiteboard?.last_edited_at}
        <p class="text-xs text-muted-foreground">
          Last edited {whiteboard.last_edited_at}
          {#if whiteboard.editor_name}
            by {whiteboard.editor_name}
          {/if}
        </p>
      {/if}
    </div>

    <div class="flex items-center gap-2">
      {#if isEditing}
        <Button variant="outline" size="sm" onclick={cancelEditing}>
          <X class="mr-1 size-4" />
          Cancel
        </Button>
        <Button size="sm" onclick={saveContent}>
          <FloppyDisk class="mr-1 size-4" />
          Save
        </Button>
      {:else}
        <Button
          variant="outline"
          size="sm"
          onclick={startEditing}
          disabled={editDisabled}
          title={editDisabledReason}>
          <PencilSimple class="mr-1 size-4" />
          Edit
        </Button>
      {/if}
    </div>
  </div>

  <!-- Disabled message -->
  {#if editDisabledReason && !isEditing}
    <div class="px-4 py-2 bg-amber-50 dark:bg-amber-950/30 text-amber-700 dark:text-amber-400 text-sm flex items-center gap-2">
      <WarningCircle class="size-4" weight="fill" />
      {editDisabledReason}
    </div>
  {/if}

  <!-- External changes warning -->
  {#if hasExternalChanges && isEditing}
    <div class="px-4 py-2 bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-400 text-sm flex items-center gap-2">
      <WarningCircle class="size-4" weight="fill" />
      Content was modified externally. Your changes may overwrite recent updates.
    </div>
  {/if}

  <!-- Content -->
  <div class="flex-1 overflow-y-auto p-4">
    {#if isEditing}
      <textarea
        bind:value={editContent}
        class="w-full h-full min-h-[300px] resize-none border border-input rounded-md px-3 py-2 text-sm bg-background font-mono
               focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent"
        placeholder="Write your whiteboard content here..."></textarea>
    {:else if whiteboard?.content}
      <div class="prose dark:prose-invert max-w-none">
        <Streamdown
          content={whiteboard.content}
          parseIncompleteMarkdown={false}
          baseTheme="shadcn" />
      </div>
    {:else}
      <p class="text-muted-foreground text-center py-8">
        No content yet. Click Edit to add content.
      </p>
    {/if}
  </div>
</div>
```

### Step 6: Create ChatWhiteboardPane Component

- [ ] Create the slide-up drawer for chat page

**File:** `app/frontend/lib/components/chat/ChatWhiteboardPane.svelte`

```svelte
<script>
  import * as Drawer from '$lib/components/shadcn/drawer/index.js';
  import WhiteboardViewer from '$lib/components/whiteboard/WhiteboardViewer.svelte';

  let {
    open = $bindable(false),
    whiteboard,
    accountId,
    agentIsResponding = false,
  } = $props();
</script>

<Drawer.Root bind:open direction="bottom">
  <Drawer.Content class="max-h-[85vh]">
    <Drawer.Header class="sr-only">
      <Drawer.Title>Whiteboard</Drawer.Title>
      <Drawer.Description>View and edit the active whiteboard</Drawer.Description>
    </Drawer.Header>

    <WhiteboardViewer
      {whiteboard}
      {accountId}
      {agentIsResponding}
      onSave={() => (open = false)}
      class="h-full" />
  </Drawer.Content>
</Drawer.Root>
```

### Step 7: Update Chat Show Page

- [ ] Add whiteboard button to settings bar
- [ ] Add ChatWhiteboardPane component
- [ ] Set up useSync for whiteboard updates

**File:** `app/frontend/pages/chats/show.svelte`

Add imports at the top:

```svelte
import { Notepad } from 'phosphor-svelte';
import ChatWhiteboardPane from '$lib/components/chat/ChatWhiteboardPane.svelte';
```

Add state:

```svelte
let whiteboardPaneOpen = $state(false);
```

Update the useSync subscriptions to include whiteboard:

```svelte
$effect(() => {
  const subs = {};
  subs[`Account:${account.id}:chats`] = 'chats';

  if (chat) {
    subs[`Chat:${chat.id}`] = ['chat', 'messages'];
    subs[`Chat:${chat.id}:messages`] = 'messages';

    // Subscribe to whiteboard updates if there's an active whiteboard
    if (chat.active_whiteboard) {
      subs[`Whiteboard:${chat.active_whiteboard.id}`] = 'chat';
    }
  }

  // ... rest of existing effect
});
```

Add button in settings bar (before the Fork button):

```svelte
{#if chat?.active_whiteboard}
  <button
    onclick={() => (whiteboardPaneOpen = true)}
    class="flex items-center gap-2 hover:opacity-80 transition-opacity text-sm text-muted-foreground">
    <Notepad size={16} weight="duotone" />
    <span>Whiteboard</span>
  </button>
{/if}
```

Add the pane component at the end of the template:

```svelte
{#if chat?.active_whiteboard}
  <ChatWhiteboardPane
    bind:open={whiteboardPaneOpen}
    whiteboard={chat.active_whiteboard}
    accountId={account.id}
    agentIsResponding={agentIsResponding} />
{/if}
```

### Step 8: Update Navbar with Agents Dropdown

- [ ] Convert Agents link to dropdown with sub-items

**File:** `app/frontend/lib/components/navigation/navbar.svelte`

Replace the Agents link in the `links` array and template with a dropdown.

Update the links array to exclude Agents:

```javascript
const links = $derived([
  { href: '/documentation', label: 'Documentation', show: true },
  {
    href: currentAccount?.id ? `/accounts/${currentAccount.id}/chats` : '#',
    label: 'Chats',
    show: !!currentUser && siteSettings?.allow_chats,
  },
  // Remove Agents from here - it becomes a dropdown
  { href: '#', label: 'About', show: true },
]);

// Add separate check for agents visibility
const showAgentsDropdown = $derived(!!currentUser && siteSettings?.allow_agents);
```

In the template, after the links loop, add the dropdown:

```svelte
{#if showAgentsDropdown}
  <DropdownMenu.Root>
    <DropdownMenu.Trigger class={cn(buttonVariants({ variant: 'ghost' }), 'rounded-full text-muted-foreground')}>
      Agents
    </DropdownMenu.Trigger>
    <DropdownMenu.Content align="start">
      <DropdownMenu.Item onclick={() => router.visit(`/accounts/${currentAccount.id}/agents`)}>
        Identities
      </DropdownMenu.Item>
      <DropdownMenu.Item onclick={() => router.visit(`/accounts/${currentAccount.id}/whiteboards`)}>
        Whiteboards
      </DropdownMenu.Item>
    </DropdownMenu.Content>
  </DropdownMenu.Root>
{/if}
```

Also update the mobile menu to include both options.

### Step 9: Create Whiteboards Index Page

- [ ] Create the whiteboards listing page

**File:** `app/frontend/pages/whiteboards/index.svelte`

```svelte
<script>
  import { useSync, createDynamicSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Notepad, ChatCircle } from 'phosphor-svelte';
  import WhiteboardViewer from '$lib/components/whiteboard/WhiteboardViewer.svelte';

  let { whiteboards = [], account } = $props();

  let selectedWhiteboard = $state(null);

  // Set up dynamic sync
  const updateSync = createDynamicSync();

  $effect(() => {
    const subs = {
      [`Account:${account.id}:whiteboards`]: 'whiteboards',
    };

    if (selectedWhiteboard) {
      subs[`Whiteboard:${selectedWhiteboard.id}`] = 'whiteboards';
    }

    updateSync(subs);
  });

  // Update selected whiteboard when whiteboards array changes
  $effect(() => {
    if (selectedWhiteboard) {
      const updated = whiteboards.find(w => w.id === selectedWhiteboard.id);
      if (updated) {
        selectedWhiteboard = updated;
      }
    }
  });

  function selectWhiteboard(whiteboard) {
    selectedWhiteboard = whiteboard;
  }

  function formatLength(length) {
    if (length >= 1000) {
      return (length / 1000).toFixed(1) + 'k chars';
    }
    return length + ' chars';
  }
</script>

<svelte:head>
  <title>Whiteboards</title>
</svelte:head>

<div class="p-8 max-w-7xl mx-auto">
  <div class="mb-8">
    <h1 class="text-3xl font-bold">Whiteboards</h1>
    <p class="text-muted-foreground mt-1">Shared workspaces for agents and humans</p>
  </div>

  {#if whiteboards.length === 0}
    <Card>
      <CardContent class="py-16 text-center">
        <Notepad class="mx-auto size-16 text-muted-foreground mb-4" weight="duotone" />
        <h2 class="text-xl font-semibold mb-2">No whiteboards yet</h2>
        <p class="text-muted-foreground">
          Whiteboards are created by agents during conversations. Start a chat with an agent to create one.
        </p>
      </CardContent>
    </Card>
  {:else}
    <div class="grid gap-6 lg:grid-cols-3">
      <!-- Whiteboards list -->
      <div class="lg:col-span-1 space-y-3">
        {#each whiteboards as whiteboard (whiteboard.id)}
          <button
            onclick={() => selectWhiteboard(whiteboard)}
            class="w-full text-left">
            <Card
              class="hover:border-primary/50 transition-colors {selectedWhiteboard?.id === whiteboard.id
                ? 'border-primary ring-1 ring-primary'
                : ''}">
              <CardContent class="p-4">
                <div class="flex items-start justify-between gap-2">
                  <div class="flex-1 min-w-0">
                    <h3 class="font-semibold truncate">{whiteboard.name}</h3>
                    {#if whiteboard.summary}
                      <p class="text-sm text-muted-foreground line-clamp-2 mt-1">
                        {whiteboard.summary}
                      </p>
                    {/if}
                  </div>
                  <Notepad class="size-5 text-muted-foreground shrink-0" weight="duotone" />
                </div>

                <div class="flex items-center gap-3 mt-3 text-xs text-muted-foreground">
                  <span>{formatLength(whiteboard.content_length)}</span>
                  <span>Rev {whiteboard.revision}</span>
                  {#if whiteboard.active_chat_count > 0}
                    <span class="flex items-center gap-1">
                      <ChatCircle class="size-3" />
                      {whiteboard.active_chat_count} {whiteboard.active_chat_count === 1 ? 'chat' : 'chats'}
                    </span>
                  {/if}
                </div>
              </CardContent>
            </Card>
          </button>
        {/each}
      </div>

      <!-- Selected whiteboard viewer -->
      <div class="lg:col-span-2">
        {#if selectedWhiteboard}
          <Card class="h-[calc(100vh-16rem)]">
            <WhiteboardViewer
              whiteboard={selectedWhiteboard}
              accountId={account.id}
              class="h-full" />
          </Card>
        {:else}
          <Card class="h-[calc(100vh-16rem)]">
            <CardContent class="h-full flex items-center justify-center">
              <div class="text-center text-muted-foreground">
                <Notepad class="mx-auto size-12 mb-4" weight="duotone" />
                <p>Select a whiteboard to view its contents</p>
              </div>
            </CardContent>
          </Card>
        {/if}
      </div>
    </div>
  {/if}
</div>
```

### Step 10: Create Whiteboards Show Page (Optional Direct Link)

- [ ] Create show page for direct whiteboard links

**File:** `app/frontend/pages/whiteboards/show.svelte`

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  import { Card } from '$lib/components/shadcn/card';
  import WhiteboardViewer from '$lib/components/whiteboard/WhiteboardViewer.svelte';

  let { whiteboard, account } = $props();

  useSync({
    [`Whiteboard:${whiteboard.id}`]: 'whiteboard',
  });
</script>

<svelte:head>
  <title>{whiteboard.name} - Whiteboard</title>
</svelte:head>

<div class="p-8 max-w-5xl mx-auto">
  <Card class="h-[calc(100vh-8rem)]">
    <WhiteboardViewer
      {whiteboard}
      accountId={account.id}
      class="h-full" />
  </Card>
</div>
```

### Step 11: Update JS Routes

- [ ] Run `rails js_routes:generate` to update routes file

After adding the routes in Rails, regenerate the JS routes:

```bash
rails js_routes:generate
```

This will add:
- `accountWhiteboardsPath(accountId)`
- `accountWhiteboardPath(accountId, id)`

---

## Real-time Sync Setup

### Step 12: Add Whiteboard Subscription to SyncChannel

- [ ] Verify Whiteboard authorization in SyncChannel

The existing `SyncAuthorizable` concern should handle this since Whiteboard `belongs_to :account`. Verify it works correctly.

**File:** `app/channels/sync_channel.rb`

The existing authorization should work:

```ruby
def can_subscribe?(key)
  # ... existing logic handles Account-scoped models ...
end
```

---

## Implementation Checklist Summary

### Backend
- [ ] Create `WhiteboardsController` with index, show, update actions
- [ ] Add whiteboard routes under accounts
- [ ] Update `ChatsController#show` to include active_whiteboard JSON
- [ ] Run `rails js_routes:generate`

### Frontend Components
- [ ] Create `WhiteboardViewer.svelte` component
- [ ] Create `ChatWhiteboardPane.svelte` component
- [ ] Update `chats/show.svelte` with whiteboard button and pane
- [ ] Update `navbar.svelte` with Agents dropdown
- [ ] Create `whiteboards/index.svelte` page
- [ ] Create `whiteboards/show.svelte` page

### Testing
- [ ] Test whiteboard button appears only when active_whiteboard exists
- [ ] Test drawer opens and displays content correctly
- [ ] Test edit mode saves content
- [ ] Test edit button disabled during agent response
- [ ] Test external changes warning appears correctly
- [ ] Test navbar dropdown navigation
- [ ] Test whiteboards index page lists all whiteboards
- [ ] Test real-time sync updates whiteboard content

---

## UI/UX Details

### Whiteboard Button Behavior
- Only visible if `chat.active_whiteboard` is set
- Located in settings bar, before the Fork button
- Uses Notepad icon with "Whiteboard" label

### Drawer Behavior
- Slides up from bottom (using vaul-svelte)
- Maximum height of 85vh
- Draggable handle at top for closing
- Click outside to close

### Edit Mode Behavior
- Edit button disabled when `agentIsResponding` is true
- Shows amber warning: "Agent is updating whiteboard..."
- When editing, tracks original revision number
- If revision changes during edit, shows red warning
- Save closes the drawer (in chat context)

### Whiteboards Index Page
- Two-column layout on large screens
- Left: List of whiteboards with key info
- Right: Selected whiteboard viewer
- Click whiteboard to select and view
- Shows character count and active chat count

---

## File Summary

### New Files
- `app/controllers/whiteboards_controller.rb`
- `app/frontend/lib/components/whiteboard/WhiteboardViewer.svelte`
- `app/frontend/lib/components/chat/ChatWhiteboardPane.svelte`
- `app/frontend/pages/whiteboards/index.svelte`
- `app/frontend/pages/whiteboards/show.svelte`

### Modified Files
- `config/routes.rb` - Add whiteboard routes
- `app/controllers/chats_controller.rb` - Add active_whiteboard to show props
- `app/frontend/pages/chats/show.svelte` - Add whiteboard button and pane
- `app/frontend/lib/components/navigation/navbar.svelte` - Add Agents dropdown
- `app/frontend/routes/index.js` - Auto-generated after `rails js_routes:generate`
