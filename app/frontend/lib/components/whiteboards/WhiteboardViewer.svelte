<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { mode } from 'mode-watcher';
  import { FloppyDisk, PencilSimple, Spinner, X } from 'phosphor-svelte';
  import { Streamdown } from 'svelte-streamdown';
  import { formatWhen } from '$lib/field.js';

  let {
    selected,
    editing = false,
    editContent = $bindable(''),
    conflict = null,
    saving = false,
    onStartEditing,
    onCancelEditing,
    onSave,
    onUseServerVersion,
    onKeepMyVersion,
  } = $props();

  const shikiTheme = $derived(mode.current === 'dark' ? 'catppuccin-mocha' : 'catppuccin-latte');
</script>

<Card.Root class="h-[calc(100vh-16rem)]">
  <div class="flex flex-col h-full">
    <div class="flex items-center justify-between px-4 py-3 border-b border-border">
      <div>
        <h3 class="font-semibold text-lg">{selected.name}</h3>
        {#if selected.dated_at}
          <p class="text-xs text-muted-foreground" data-testid="note-dated-at">Dated {formatWhen(selected.dated_at)}</p>
        {/if}
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
          <Button variant="outline" size="sm" onclick={onCancelEditing} disabled={saving}>
            <X class="mr-1 size-4" />
            Cancel
          </Button>
          <Button size="sm" onclick={onSave} disabled={saving}>
            {#if saving}
              <Spinner class="mr-1 size-4 animate-spin" />
            {:else}
              <FloppyDisk class="mr-1 size-4" />
            {/if}
            Save
          </Button>
        {:else}
          <Button variant="outline" size="sm" onclick={onStartEditing}>
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
          <Button variant="outline" size="sm" onclick={onUseServerVersion}>Use their version</Button>
          <Button size="sm" onclick={onKeepMyVersion}>Keep mine and save</Button>
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
          <Streamdown
            content={selected.content}
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
</Card.Root>
