<script>
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { Tag, Check } from 'phosphor-svelte';
  import { reloadProps } from '$lib/cable';
  import { visualTagColour } from '$lib/visual-tags';
  import VisualTagIcon from './VisualTagIcon.svelte';

  let { chat, accountId, tags = [] } = $props();
  let error = $state('');
  // The choice shows at once and the save runs in the background; nothing waits
  // for the conversation list to reload. Three layers, highest first:
  // - `optimistic`: the last click, while any save for it is in flight or queued;
  // - `confirmed`: the last tag the server acknowledged, with the row's updated_at
  //   from that write. It is the rollback target if a later save fails, and it
  //   holds until a list snapshot at least that new arrives, so a refresh that
  //   read the row before the write can't put an older tag back;
  // - the `chat` prop.
  let optimistic = $state(undefined);
  let confirmed = $state(null);
  let saving = false;
  let queued = undefined;

  const time = (value) => (value ? Date.parse(value) : NaN);
  // A snapshot supersedes the acknowledged write when it is at least as new. Without
  // a timestamp, only a snapshot that already shows the acknowledged tag does.
  function supersedes(row, ack) {
    const rowAt = time(row.updated_at);
    const ackAt = time(ack.at);
    if (!Number.isNaN(rowAt) && !Number.isNaN(ackAt)) return rowAt >= ackAt;
    return (row.visual_tag?.id || null) === (ack.tag?.id || null);
  }

  const current = $derived(
    optimistic !== undefined ? optimistic : confirmed && !supersedes(chat, confirmed) ? confirmed.tag : chat.visual_tag
  );
  const label = $derived(current?.label || 'No tag');

  $effect(() => {
    if (confirmed && supersedes(chat, confirmed)) confirmed = null;
  });

  function selectTag(id) {
    if ((current?.id || null) === id) return;
    error = '';
    optimistic = id === null ? null : tags.find((tag) => tag.id === id) || null;
    if (saving) {
      queued = id; // one write at a time, so the last click is the one that lands
      return;
    }
    save(id);
  }

  async function save(id) {
    saving = true;
    let result = null;
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
      if (response.ok) result = await response.json();
    } catch {
      result = null;
    }
    saving = false;
    if (result) confirmed = { tag: result.visual_tag || null, at: result.updated_at };
    if (queued !== undefined) {
      const next = queued;
      queued = undefined;
      save(next);
      return;
    }
    optimistic = undefined;
    if (!result) error = 'Could not change visual tag. Please try again.';
    // The account broadcast refreshes these too; asking directly covers a dropped socket
    // and, after a failure, shows whatever the server really holds.
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
