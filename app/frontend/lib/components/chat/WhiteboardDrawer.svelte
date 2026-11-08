<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Drawer from '$lib/components/shadcn/drawer/index.js';
  import { Spinner, PencilSimple, FloppyDisk, X, WarningCircle } from 'phosphor-svelte';
  import { Streamdown } from 'svelte-streamdown';
  import { LINK_PREFIXES } from '$lib/markdown-links.js';

  let {
    open = $bindable(false),
    whiteboard,
    accountId,
    agentIsResponding = false,
    shikiTheme = 'catppuccin-latte',
  } = $props();

  let editing = $state(false);
  let editContent = $state('');
  let conflict = $state(null);
  let saving = $state(false);

  function startEditing() {
    editContent = whiteboard?.content || '';
    editing = true;
  }

  function cancelEditing() {
    editing = false;
    editContent = '';
    conflict = null;
  }

  async function save() {
    if (!whiteboard) return;

    saving = true;
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');

    try {
      const response = await fetch(`/accounts/${accountId}/whiteboards/${whiteboard.id}`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken || '',
        },
        body: JSON.stringify({
          whiteboard: { content: editContent },
          expected_revision: whiteboard.revision,
        }),
      });

      if (response.ok) {
        editing = false;
        open = false;
        conflict = null;
        saving = false;
        router.reload({ only: ['chat', 'messages'], preserveScroll: true });
      } else {
        const data = await response.json();
        saving = false;
        if (data.error === 'conflict') {
          conflict = {
            serverContent: data.current_content,
            serverRevision: data.current_revision,
            myContent: editContent,
          };
        } else {
          alert('Failed to save. Please try again.');
        }
      }
    } catch (error) {
      saving = false;
      alert('Failed to save. Please try again.');
    }
  }

  function useServerVersion() {
    if (!conflict) return;
    editContent = conflict.serverContent;
    conflict = null;
  }

  function keepMyVersion() {
    conflict = null;
    save();
  }
</script>

<Drawer.Root bind:open direction="bottom">
  <Drawer.Content class="max-h-[85vh]">
    <Drawer.Header class="sr-only">
      <Drawer.Title>Whiteboard</Drawer.Title>
      <Drawer.Description>View and edit the active whiteboard</Drawer.Description>
    </Drawer.Header>

    <div class="flex flex-col h-full max-h-[80vh]">
      <div class="flex items-center justify-between px-4 py-3 border-b border-border">
        <div>
          <h3 class="font-semibold text-lg">{whiteboard?.name}</h3>
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
          {#if editing}
            <Button variant="outline" size="sm" onclick={cancelEditing} disabled={saving}>
              <X class="mr-1 size-4" />
              Cancel
            </Button>
            <Button size="sm" onclick={save} disabled={saving}>
              {#if saving}
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
              onclick={startEditing}
              disabled={agentIsResponding}
              title={agentIsResponding ? 'Resident is updating whiteboard...' : undefined}>
              <PencilSimple class="mr-1 size-4" />
              Edit
            </Button>
          {/if}
        </div>
      </div>

      {#if conflict}
        <div class="px-4 py-3 bg-amber-50 dark:bg-amber-950/30 border-b border-amber-200 dark:border-amber-800">
          <p class="font-semibold text-amber-800 dark:text-amber-200 mb-1">Someone else edited this whiteboard</p>
          <p class="text-sm text-amber-700 dark:text-amber-300 mb-3">
            Your changes have been preserved. Choose which version to keep:
          </p>
          <div class="flex gap-2">
            <Button variant="outline" size="sm" onclick={useServerVersion}>Use their version</Button>
            <Button size="sm" onclick={keepMyVersion}>Keep mine and save</Button>
          </div>
        </div>
      {/if}

      {#if agentIsResponding && !editing}
        <div
          class="px-4 py-2 bg-amber-50 dark:bg-amber-950/30 text-amber-700 dark:text-amber-400 text-sm flex items-center gap-2">
          <WarningCircle class="size-4" weight="fill" />
          Resident is updating whiteboard...
        </div>
      {/if}

      <div class="flex-1 overflow-y-auto p-4">
        {#if editing}
          <textarea
            bind:value={editContent}
            class="w-full h-full min-h-[300px] resize-none border border-input rounded-md px-3 py-2 text-sm bg-background font-mono
                   focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent"
            placeholder="Write your whiteboard content here..."></textarea>
        {:else if whiteboard?.content?.trim()}
          <div class="prose dark:prose-invert max-w-none">
            <Streamdown
              allowedLinkPrefixes={LINK_PREFIXES}
              content={whiteboard.content}
              parseIncompleteMarkdown={false}
              baseTheme="shadcn"
              {shikiTheme}
              shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']} />
          </div>
        {:else}
          <p class="text-muted-foreground text-center py-8">No content yet. Click Edit to add content.</p>
        {/if}
      </div>
    </div>
  </Drawer.Content>
</Drawer.Root>
