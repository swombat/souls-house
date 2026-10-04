<script>
  import { router } from '@inertiajs/svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { Tag, Check } from 'phosphor-svelte';
  import { visualTagIcon, visualTagColour } from '$lib/visual-tags';

  let { chat, accountId, tags = [] } = $props();
  let saving = $state(false);
  let error = $state('');
  const Icon = $derived(chat.visual_tag ? visualTagIcon(chat.visual_tag.icon) : Tag);
  const label = $derived(chat.visual_tag?.label || 'No tag');

  function selectTag(id) {
    if (saving || (chat.visual_tag?.id || null) === id) return;
    saving = true;
    error = '';
    router.patch(
      `/accounts/${accountId}/chats/${chat.id}/visual_tag`,
      { visual_tag_id: id },
      {
        preserveScroll: true,
        preserveState: true,
        onError: () => (error = 'Could not change visual tag. Please try again.'),
        onFinish: () => (saving = false),
      }
    );
  }
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger
    class="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded hover:bg-muted focus-visible:outline focus-visible:outline-2 {chat.visual_tag
      ? visualTagColour(chat.visual_tag.colour)
      : 'text-muted-foreground/60'}"
    aria-label={`Change visual tag: ${label}`}
    title={label}
    disabled={saving || chat.discarded}>
    <Icon size={16} weight={chat.visual_tag ? 'duotone' : 'regular'} />
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="start" class="w-56 max-h-80 overflow-y-auto">
    <DropdownMenu.Label>Visual tag</DropdownMenu.Label>
    <DropdownMenu.Item onclick={() => selectTag(null)}>
      <Tag size={16} class="mr-2 text-muted-foreground" />
      No tag
      {#if !chat.visual_tag}<Check size={14} class="ml-auto" />{/if}
    </DropdownMenu.Item>
    <DropdownMenu.Separator />
    {#each tags as tag (tag.id)}
      {@const TagIcon = visualTagIcon(tag.icon)}
      <DropdownMenu.Item onclick={() => selectTag(tag.id)}>
        <TagIcon size={16} class={`mr-2 shrink-0 ${visualTagColour(tag.colour)}`} weight="duotone" />
        <span class="truncate">{tag.label}</span>
        {#if chat.visual_tag?.id === tag.id}<Check size={14} class="ml-auto shrink-0" />{/if}
      </DropdownMenu.Item>
    {/each}
  </DropdownMenu.Content>
</DropdownMenu.Root>
{#if error}
  <span role="alert" class="absolute left-2 top-full z-50 rounded border bg-background p-2 text-xs text-destructive">
    {error}
  </span>
{/if}
