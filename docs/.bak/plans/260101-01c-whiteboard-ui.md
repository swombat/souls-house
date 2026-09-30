# Whiteboard UI Implementation Specification (Revision C)

## Overview

Final revision addressing DHH's remaining feedback. Key changes from Revision B:

1. **Conflict UX** - Show both versions, let user choose (no lost work)
2. **Mobile dropdown labels** - Clean labels: "Identities" and "Whiteboards"
3. **Remove formatLength** - Inline the ternary
4. **Error handling** - Network failures, 404s, 500s
5. **Consistent channel naming** - Use descriptive prop names throughout

---

## Backend Changes

### Step 1: Create WhiteboardsController

- [ ] Create controller with `index` and `update` actions

**File:** `app/controllers/whiteboards_controller.rb`

```ruby
class WhiteboardsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_whiteboard, only: [:update]

  def index
    @whiteboards = current_account.whiteboards.active.by_name
    chat_counts = Chat.where(active_whiteboard_id: @whiteboards.pluck(:id))
                      .group(:active_whiteboard_id)
                      .count

    render inertia: "whiteboards/index", props: {
      whiteboards: @whiteboards.map { |w| whiteboard_json(w, chat_counts[w.id] || 0) },
      account: current_account.as_json
    }
  end

  def update
    if params[:expected_revision].present? && @whiteboard.revision != params[:expected_revision].to_i
      render json: {
        error: "conflict",
        current_content: @whiteboard.content,
        current_revision: @whiteboard.revision
      }, status: :conflict
      return
    end

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

  def whiteboard_json(whiteboard, active_chat_count = 0)
    {
      id: whiteboard.id,
      name: whiteboard.name,
      summary: whiteboard.summary,
      content: whiteboard.content,
      content_length: whiteboard.content.to_s.length,
      revision: whiteboard.revision,
      last_edited_at: whiteboard.last_edited_at&.strftime("%b %d at %l:%M %p"),
      editor_name: whiteboard.editor_name,
      active_chat_count: active_chat_count
    }
  end

end
```

**Key change:** Conflict response now returns `current_content` and `current_revision` so frontend can offer choices.

### Step 2: Add Routes

- [ ] Add whiteboard routes

**File:** `config/routes.rb`

Add within the `resources :accounts` block:

```ruby
resources :whiteboards, only: [:index, :update]
```

### Step 3: Update ChatsController

- [ ] Add whiteboard data to chat show props

**File:** `app/controllers/chats_controller.rb`

Update the `show` action to include whiteboard data:

```ruby
def show
  @chats = current_account.chats.latest
  @messages = @chat.messages.includes(:user, :agent).with_attached_attachments.sorted

  render inertia: "chats/show", props: {
    chat: chat_json_with_whiteboard,
    chats: @chats.as_json,
    messages: @messages.all.collect(&:as_json),
    account: current_account.as_json,
    models: available_models,
    agents: @chat.group_chat? ? @chat.agents.as_json : [],
    file_upload_config: file_upload_config
  }
end

private

def chat_json_with_whiteboard
  json = @chat.as_json
  if @chat.active_whiteboard&.active?
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

### Step 4: Regenerate JS Routes

- [ ] Run `rails js_routes:generate`

---

## Frontend Changes

### Step 5: Update Chat Show Page with Inline Drawer

- [ ] Add whiteboard button and drawer to `chats/show.svelte`

**File:** `app/frontend/pages/chats/show.svelte`

Add to imports:

```svelte
import { Notepad, FloppyDisk, PencilSimple, X, WarningCircle } from 'phosphor-svelte';
import * as Drawer from '$lib/components/shadcn/drawer/index.js';
```

Add state variables after existing state declarations:

```svelte
let whiteboardOpen = $state(false);
let whiteboardEditing = $state(false);
let whiteboardEditContent = $state('');
let whiteboardConflict = $state(null);
let whiteboardSaving = $state(false);
```

Add to the useSync subscriptions effect (inside the `if (chat)` block, after the existing subscriptions):

```svelte
if (chat.active_whiteboard) {
  subs[`Whiteboard:${chat.active_whiteboard.id}`] = ['chat', 'messages'];
}
```

Add whiteboard functions after `forkConversation`:

```svelte
function saveWhiteboard() {
  if (!chat?.active_whiteboard) return;

  whiteboardSaving = true;
  router.patch(
    `/accounts/${account.id}/whiteboards/${chat.active_whiteboard.id}`,
    {
      whiteboard: { content: whiteboardEditContent },
      expected_revision: chat.active_whiteboard.revision,
    },
    {
      preserveScroll: true,
      onSuccess: () => {
        whiteboardEditing = false;
        whiteboardOpen = false;
        whiteboardConflict = null;
        whiteboardSaving = false;
      },
      onError: (errors) => {
        whiteboardSaving = false;
        if (errors.error === 'conflict') {
          whiteboardConflict = {
            serverContent: errors.current_content,
            serverRevision: errors.current_revision,
            myContent: whiteboardEditContent,
          };
        } else {
          alert('Failed to save. Please try again.');
        }
      },
    }
  );
}

function useServerVersion() {
  if (!whiteboardConflict) return;
  whiteboardEditContent = whiteboardConflict.serverContent;
  whiteboardConflict = null;
}

function keepMyVersion() {
  whiteboardConflict = null;
  saveWhiteboard();
}

function startEditingWhiteboard() {
  whiteboardEditContent = chat?.active_whiteboard?.content || '';
  whiteboardEditing = true;
}

function cancelEditingWhiteboard() {
  whiteboardEditing = false;
  whiteboardEditContent = '';
  whiteboardConflict = null;
}
```

Add whiteboard button in the settings bar (after the Fork button):

```svelte
{#if chat?.active_whiteboard}
  <button
    onclick={() => whiteboardOpen = true}
    class="flex items-center gap-2 hover:opacity-80 transition-opacity text-sm text-muted-foreground">
    <Notepad size={16} weight="duotone" />
    <span>Whiteboard</span>
  </button>
{/if}
```

Add the drawer at the end of the component, before the closing `</div>`:

```svelte
{#if chat?.active_whiteboard}
  <Drawer.Root bind:open={whiteboardOpen} direction="bottom">
    <Drawer.Content class="max-h-[85vh]">
      <Drawer.Header class="sr-only">
        <Drawer.Title>Whiteboard</Drawer.Title>
        <Drawer.Description>View and edit the active whiteboard</Drawer.Description>
      </Drawer.Header>

      <div class="flex flex-col h-full max-h-[80vh]">
        <div class="flex items-center justify-between px-4 py-3 border-b border-border">
          <div>
            <h3 class="font-semibold text-lg">{chat.active_whiteboard.name}</h3>
            {#if chat.active_whiteboard.last_edited_at}
              <p class="text-xs text-muted-foreground">
                Last edited {chat.active_whiteboard.last_edited_at}
                {#if chat.active_whiteboard.editor_name}
                  by {chat.active_whiteboard.editor_name}
                {/if}
              </p>
            {/if}
          </div>

          <div class="flex items-center gap-2">
            {#if whiteboardEditing}
              <Button variant="outline" size="sm" onclick={cancelEditingWhiteboard} disabled={whiteboardSaving}>
                <X class="mr-1 size-4" />
                Cancel
              </Button>
              <Button size="sm" onclick={saveWhiteboard} disabled={whiteboardSaving}>
                {#if whiteboardSaving}
                  <Spinner class="mr-1 size-4 animate-spin" />
                {:else}
                  <FloppyDisk class="mr-1 size-4" />
                {/if}
                Save
              </Button>
            {:else}
              <Button
                variant="outline"
                size="sm"
                onclick={startEditingWhiteboard}
                disabled={agentIsResponding}
                title={agentIsResponding ? 'Agent is updating whiteboard...' : undefined}>
                <PencilSimple class="mr-1 size-4" />
                Edit
              </Button>
            {/if}
          </div>
        </div>

        {#if whiteboardConflict}
          <div class="px-4 py-3 bg-amber-50 dark:bg-amber-950/30 border-b border-amber-200 dark:border-amber-800">
            <p class="font-semibold text-amber-800 dark:text-amber-200 mb-1">Someone else edited this whiteboard</p>
            <p class="text-sm text-amber-700 dark:text-amber-300 mb-3">Your changes have been preserved. Choose which version to keep:</p>
            <div class="flex gap-2">
              <Button variant="outline" size="sm" onclick={useServerVersion}>
                Use their version
              </Button>
              <Button size="sm" onclick={keepMyVersion}>
                Keep mine and save
              </Button>
            </div>
          </div>
        {/if}

        {#if agentIsResponding && !whiteboardEditing}
          <div class="px-4 py-2 bg-amber-50 dark:bg-amber-950/30 text-amber-700 dark:text-amber-400 text-sm flex items-center gap-2">
            <WarningCircle class="size-4" weight="fill" />
            Agent is updating whiteboard...
          </div>
        {/if}

        <div class="flex-1 overflow-y-auto p-4">
          {#if whiteboardEditing}
            <textarea
              bind:value={whiteboardEditContent}
              class="w-full h-full min-h-[300px] resize-none border border-input rounded-md px-3 py-2 text-sm bg-background font-mono
                     focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent"
              placeholder="Write your whiteboard content here..."></textarea>
          {:else if chat.active_whiteboard.content?.trim()}
            <div class="prose dark:prose-invert max-w-none">
              <Streamdown
                content={chat.active_whiteboard.content}
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
    </Drawer.Content>
  </Drawer.Root>
{/if}
```

### Step 6: Update Navbar with Agents Dropdown

- [ ] Convert Agents link to dropdown with Identities and Whiteboards

**File:** `app/frontend/lib/components/navigation/navbar.svelte`

Update the `links` array to remove Agents:

```javascript
const links = $derived([
  { href: '/documentation', label: 'Documentation', show: true },
  {
    href: currentAccount?.id ? `/accounts/${currentAccount.id}/chats` : '#',
    label: 'Chats',
    show: !!currentUser && siteSettings?.allow_chats,
  },
  { href: '#', label: 'About', show: true },
]);

const showAgentsDropdown = $derived(!!currentUser && siteSettings?.allow_agents && currentAccount?.id);
```

In the desktop navigation section, after the links loop, add the dropdown:

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

Update the mobile menu (clean labels, no "Agents -" prefix):

```svelte
{#if siteSettings?.allow_agents && currentAccount?.id}
  <DropdownMenu.Item onclick={() => router.visit(`/accounts/${currentAccount.id}/agents`)}>
    Identities
  </DropdownMenu.Item>
  <DropdownMenu.Item onclick={() => router.visit(`/accounts/${currentAccount.id}/whiteboards`)}>
    Whiteboards
  </DropdownMenu.Item>
{/if}
```

### Step 7: Create Whiteboards Index Page

- [ ] Create index page with URL-based selection

**File:** `app/frontend/pages/whiteboards/index.svelte`

```svelte
<script>
  import { page, router } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Notepad, ChatCircle, PencilSimple, FloppyDisk, X, Spinner } from 'phosphor-svelte';
  import { Streamdown } from 'svelte-streamdown';

  let { whiteboards = [], account } = $props();

  const selectedId = $derived($page.url.searchParams.get('id'));
  const selected = $derived(whiteboards.find((w) => w.id === Number(selectedId)));

  let editing = $state(false);
  let editContent = $state('');
  let conflict = $state(null);
  let saving = $state(false);

  const updateSync = createDynamicSync();

  $effect(() => {
    const subs = {
      [`Account:${account.id}:whiteboards`]: 'whiteboards',
    };
    if (selected) {
      subs[`Whiteboard:${selected.id}`] = 'whiteboards';
    }
    updateSync(subs);
  });

  function selectWhiteboard(id) {
    editing = false;
    conflict = null;
    router.get(`/accounts/${account.id}/whiteboards`, { id }, { preserveState: true, preserveScroll: true });
  }

  function startEditing() {
    editContent = selected?.content || '';
    editing = true;
  }

  function cancelEditing() {
    editing = false;
    editContent = '';
    conflict = null;
  }

  function saveWhiteboard() {
    saving = true;
    router.patch(
      `/accounts/${account.id}/whiteboards/${selected.id}`,
      {
        whiteboard: { content: editContent },
        expected_revision: selected.revision,
      },
      {
        preserveScroll: true,
        onSuccess: () => {
          editing = false;
          conflict = null;
          saving = false;
        },
        onError: (errors) => {
          saving = false;
          if (errors.error === 'conflict') {
            conflict = {
              serverContent: errors.current_content,
              serverRevision: errors.current_revision,
              myContent: editContent,
            };
          } else {
            alert('Failed to save. Please try again.');
          }
        },
      }
    );
  }

  function useServerVersion() {
    if (!conflict) return;
    editContent = conflict.serverContent;
    conflict = null;
  }

  function keepMyVersion() {
    conflict = null;
    saveWhiteboard();
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
    <Card.Root>
      <Card.Content class="py-16 text-center">
        <Notepad class="mx-auto size-16 text-muted-foreground mb-4" weight="duotone" />
        <h2 class="text-xl font-semibold mb-2">No whiteboards yet</h2>
        <p class="text-muted-foreground">
          Whiteboards are created by agents during conversations. Start a chat with an agent to create one.
        </p>
      </Card.Content>
    </Card.Root>
  {:else}
    <div class="grid gap-6 lg:grid-cols-3">
      <!-- Whiteboards list -->
      <div class="space-y-3">
        {#each whiteboards as wb (wb.id)}
          <button onclick={() => selectWhiteboard(wb.id)} class="w-full text-left">
            <Card.Root
              class="hover:border-primary/50 transition-colors {selected?.id === wb.id
                ? 'border-primary ring-1 ring-primary'
                : ''}">
              <Card.Content class="p-4">
                <div class="flex items-start justify-between gap-2">
                  <div class="flex-1 min-w-0">
                    <h3 class="font-semibold truncate">{wb.name}</h3>
                    {#if wb.summary}
                      <p class="text-sm text-muted-foreground line-clamp-2 mt-1">{wb.summary}</p>
                    {/if}
                  </div>
                  <Notepad class="size-5 text-muted-foreground shrink-0" weight="duotone" />
                </div>

                <div class="flex items-center gap-3 mt-3 text-xs text-muted-foreground">
                  <span>{wb.content_length >= 1000 ? `${(wb.content_length / 1000).toFixed(1)}k` : wb.content_length} chars</span>
                  <span>Rev {wb.revision}</span>
                  {#if wb.active_chat_count > 0}
                    <span class="flex items-center gap-1">
                      <ChatCircle class="size-3" />
                      {wb.active_chat_count}
                      {wb.active_chat_count === 1 ? 'chat' : 'chats'}
                    </span>
                  {/if}
                </div>
              </Card.Content>
            </Card.Root>
          </button>
        {/each}
      </div>

      <!-- Selected whiteboard viewer -->
      <div class="lg:col-span-2">
        {#if selected}
          <Card.Root class="h-[calc(100vh-16rem)]">
            <div class="flex flex-col h-full">
              <div class="flex items-center justify-between px-4 py-3 border-b border-border">
                <div>
                  <h3 class="font-semibold text-lg">{selected.name}</h3>
                  {#if selected.last_edited_at}
                    <p class="text-xs text-muted-foreground">
                      Last edited {selected.last_edited_at}
                      {#if selected.editor_name}
                        by {selected.editor_name}
                      {/if}
                    </p>
                  {/if}
                </div>

                <div class="flex items-center gap-2">
                  {#if editing}
                    <Button variant="outline" size="sm" onclick={cancelEditing} disabled={saving}>
                      <X class="mr-1 size-4" />
                      Cancel
                    </Button>
                    <Button size="sm" onclick={saveWhiteboard} disabled={saving}>
                      {#if saving}
                        <Spinner class="mr-1 size-4 animate-spin" />
                      {:else}
                        <FloppyDisk class="mr-1 size-4" />
                      {/if}
                      Save
                    </Button>
                  {:else}
                    <Button variant="outline" size="sm" onclick={startEditing}>
                      <PencilSimple class="mr-1 size-4" />
                      Edit
                    </Button>
                  {/if}
                </div>
              </div>

              {#if conflict}
                <div class="px-4 py-3 bg-amber-50 dark:bg-amber-950/30 border-b border-amber-200 dark:border-amber-800">
                  <p class="font-semibold text-amber-800 dark:text-amber-200 mb-1">Someone else edited this whiteboard</p>
                  <p class="text-sm text-amber-700 dark:text-amber-300 mb-3">Your changes have been preserved. Choose which version to keep:</p>
                  <div class="flex gap-2">
                    <Button variant="outline" size="sm" onclick={useServerVersion}>
                      Use their version
                    </Button>
                    <Button size="sm" onclick={keepMyVersion}>
                      Keep mine and save
                    </Button>
                  </div>
                </div>
              {/if}

              <div class="flex-1 overflow-y-auto p-4">
                {#if editing}
                  <textarea
                    bind:value={editContent}
                    class="w-full h-full min-h-[300px] resize-none border border-input rounded-md px-3 py-2 text-sm bg-background font-mono
                           focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent"
                    placeholder="Write your whiteboard content here..."></textarea>
                {:else if selected.content?.trim()}
                  <div class="prose dark:prose-invert max-w-none">
                    <Streamdown content={selected.content} parseIncompleteMarkdown={false} baseTheme="shadcn" />
                  </div>
                {:else}
                  <p class="text-muted-foreground text-center py-8">No content yet. Click Edit to add content.</p>
                {/if}
              </div>
            </div>
          </Card.Root>
        {:else}
          <Card.Root class="h-[calc(100vh-16rem)]">
            <Card.Content class="h-full flex items-center justify-center">
              <div class="text-center text-muted-foreground">
                <Notepad class="mx-auto size-12 mb-4" weight="duotone" />
                <p>Select a whiteboard to view its contents</p>
              </div>
            </Card.Content>
          </Card.Root>
        {/if}
      </div>
    </div>
  {/if}
</div>
```

---

## Implementation Checklist

### Backend
- [ ] Create `WhiteboardsController` with `index` and `update` actions
- [ ] Add whiteboard routes (`index`, `update` only)
- [ ] Update `ChatsController#show` to include `active_whiteboard` JSON
- [ ] Run `rails js_routes:generate`

### Frontend
- [ ] Update `chats/show.svelte` with inline whiteboard drawer
- [ ] Update `navbar.svelte` with Agents dropdown
- [ ] Create `whiteboards/index.svelte` page

### Testing
- [ ] Whiteboard button only appears when `chat.active_whiteboard` exists
- [ ] Drawer opens and displays markdown content correctly
- [ ] Edit mode saves content and closes drawer
- [ ] Edit button disabled during agent streaming
- [ ] Conflict returns 409 with current content
- [ ] Conflict UI shows both versions, allows choice
- [ ] User work is never lost on conflict
- [ ] Navbar dropdown navigates correctly
- [ ] Mobile menu shows clean labels (no "Agents -" prefix)
- [ ] Index page URL-based selection works
- [ ] Real-time sync updates whiteboard content in both views
- [ ] Save button shows loading state during PATCH
- [ ] Network errors show generic retry message

---

## Changes from Revision B

| Issue | Fix |
|-------|-----|
| `alert()` on conflict | Show inline conflict UI with both versions |
| User loses work on conflict | Preserve user content, let them choose |
| "Agents - Identities" mobile label | Just "Identities" |
| "Agents - Whiteboards" mobile label | Just "Whiteboards" |
| `formatLength()` function | Inline ternary in template |
| No loading state on save | Added `whiteboardSaving` / `saving` state |
| Missing error handling | Generic error message for non-conflict errors |
| Inconsistent channel naming | Use `['chat', 'messages']` consistently for whiteboard sync |
| No `.trim()` check for empty content | Added `content?.trim()` check |

---

## Key Design Decisions

### 1. Conflict Resolution Without Data Loss

When a conflict occurs, the server returns the current content:

```ruby
render json: {
  error: "conflict",
  current_content: @whiteboard.content,
  current_revision: @whiteboard.revision
}, status: :conflict
```

The frontend stores both versions:

```javascript
conflict = {
  serverContent: errors.current_content,
  serverRevision: errors.current_revision,
  myContent: editContent,
};
```

User can then choose:
- **Use their version**: Replace edit content with server content, continue editing
- **Keep mine and save**: Retry save with their content (will succeed since revision now matches)

### 2. No Component Abstraction

The whiteboard viewer code is duplicated in two places. This is intentional:
- Only two call sites
- Slightly different behavior (drawer closes on save, index stays open)
- If a third use case emerges, extract then

### 3. URL-Based State on Index

Selection state lives in the URL (`?id=123`):
- Back button works
- Bookmarkable links
- The Rails Way translated to Inertia

### 4. Inline Length Formatting

Instead of a function:

```svelte
<span>{wb.content_length >= 1000 ? `${(wb.content_length / 1000).toFixed(1)}k` : wb.content_length} chars</span>
```

One use site does not justify a function.

---

## File Summary

### New Files
- `app/controllers/whiteboards_controller.rb`
- `app/frontend/pages/whiteboards/index.svelte`

### Modified Files
- `config/routes.rb` - Add whiteboard routes
- `app/controllers/chats_controller.rb` - Add active_whiteboard to show props
- `app/frontend/pages/chats/show.svelte` - Add whiteboard button and drawer
- `app/frontend/lib/components/navigation/navbar.svelte` - Add Agents dropdown
- `app/frontend/routes/index.js` - Auto-generated after `rails js_routes:generate`

---

## Estimated Implementation Time

4-6 hours for a developer familiar with the codebase.
