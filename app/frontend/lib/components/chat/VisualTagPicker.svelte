<script>
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { Tag, Check } from 'phosphor-svelte';
  import { reloadProps } from '$lib/cable';
  import { visualTagColour } from '$lib/visual-tags';
  import VisualTagIcon from './VisualTagIcon.svelte';

  let { chat, accountId, tags = [] } = $props();
  let error = $state('');
  // The choice shows at once and the save runs in the background; nothing waits
  // for the conversation list to reload. `shown` is the optimistic tag (null =
  // no tag) until the next props for this row arrive, then the server's again.
  let shown = $state(undefined);
  let saving = false;
  let queued = undefined;
  let settled = false;
  const current = $derived(shown === undefined ? chat.visual_tag : shown);
  const label = $derived(current?.label || 'No tag');

  $effect(() => {
    chat;
    if (settled && !saving) {
      settled = false;
      shown = undefined;
    }
  });

  function selectTag(id) {
    if ((current?.id || null) === id) return;
    error = '';
    shown = id === null ? null : tags.find((tag) => tag.id === id) || null;
    settled = false;
    if (saving) {
      queued = id; // one write at a time, so the last click is the one that lands
      return;
    }
    save(id);
  }

  async function save(id) {
    saving = true;
    let ok = false;
    try {
      const response = await fetch(`/accounts/${accountId}/chats/${chat.id}/visual_tag`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        body: JSON.stringify({ visual_tag_id: id }),
      });
      ok = response.ok;
    } catch {
      ok = false;
    }
    saving = false;
    if (queued !== undefined) {
      const next = queued;
      queued = undefined;
      save(next);
      return;
    }
    if (!ok) {
      shown = undefined;
      error = 'Could not change visual tag. Please try again.';
      return;
    }
    settled = true;
    // The account broadcast refreshes these too; asking directly covers a dropped socket.
    reloadProps(['chats', 'visual_tags']);
  }
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger
    class="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded hover:bg-muted focus-visible:outline focus-visible:outline-2 {current
      ? visualTagColour(current.colour)
      : 'text-muted-foreground/20 hover:text-muted-foreground/70 focus-visible:text-muted-foreground/70'}"
    aria-label={`Change visual tag: ${label}`}
    title={label}
    disabled={chat.discarded}>
    {#if current}
      <VisualTagIcon icon={current.icon} size={16} />
    {:else}
      <Tag size={16} />
    {/if}
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="start" class="w-56 max-h-80 overflow-y-auto">
    <DropdownMenu.Label>Visual tag</DropdownMenu.Label>
    <DropdownMenu.Item onclick={() => selectTag(null)}>
      <Tag size={16} class="mr-2 text-muted-foreground" />
      No tag
      {#if !current}<Check size={14} class="ml-auto" />{/if}
    </DropdownMenu.Item>
    <DropdownMenu.Separator />
    {#each tags as tag (tag.id)}
      <DropdownMenu.Item onclick={() => selectTag(tag.id)}>
        <VisualTagIcon icon={tag.icon} size={16} class={`mr-2 shrink-0 ${visualTagColour(tag.colour)}`} />
        <span class="truncate">{tag.label}</span>
        {#if current?.id === tag.id}<Check size={14} class="ml-auto shrink-0" />{/if}
      </DropdownMenu.Item>
    {/each}
  </DropdownMenu.Content>
</DropdownMenu.Root>
{#if error}
  <span role="alert" class="absolute left-2 top-full z-50 rounded border bg-background p-2 text-xs text-destructive">
    {error}
  </span>
{/if}
