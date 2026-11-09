<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Popover from '$lib/components/shadcn/popover/index.js';
  import { Archive, Check, EyeSlash, FunnelSimple, Plus, Trash, X } from 'phosphor-svelte';
  import RoomSwitcher from './RoomSwitcher.svelte';
  import VisualTagIcon from './VisualTagIcon.svelte';
  import { visualTagColour } from '$lib/visual-tags';
  import { ADMIN_ONLY_TEXT } from '$lib/admin-only.js';

  let {
    accountId,
    hasRooms = false,
    canSeeDeleted = false,
    deletedIsAdminOnly = false,
    showArchived = false,
    showDeleted = false,
    showHidden = false,
    hiddenAttentionCount = 0,
    visualTags = [],
    selectedTagId = null,
    onCreate,
    onClose,
    onToggleArchived,
    onToggleDeleted,
    onToggleHidden = () => {},
    onSelectTag = () => {},
  } = $props();

  let open = $state(false);
  const selectedTag = $derived(visualTags.find((tag) => tag.id === selectedTagId) || null);
  const activeCount = $derived(
    [showArchived, canSeeDeleted && showDeleted, showHidden, Boolean(selectedTag)].filter(Boolean).length
  );
  const triggerLabel = $derived(
    [
      'Filter conversations',
      activeCount > 0 ? `${activeCount} on` : null,
      !showHidden && hiddenAttentionCount > 0 ? `${hiddenAttentionCount} hidden waiting on you` : null,
    ]
      .filter(Boolean)
      .join(', ')
  );
  const checkboxClass =
    'w-3 h-3 rounded border-gray-300 text-primary focus:ring-primary focus:ring-offset-0 focus:ring-1 transition-colors cursor-pointer';

  function selectTag(tag) {
    open = false;
    onSelectTag(selectedTagId === tag.id ? null : tag.id);
  }
</script>

<header class="p-4 border-b border-border bg-muted/30">
  <div class="flex items-center justify-between mb-3">
    {#if hasRooms}
      <RoomSwitcher {accountId} />
    {:else}
      <h2 class="text-lg font-semibold">Chats</h2>
    {/if}
    <div class="flex items-center gap-2">
      <Button variant="outline" size="sm" onclick={onCreate} class="h-8 w-8 p-0" aria-label="New chat">
        <Plus size={16} />
      </Button>
      <Button variant="ghost" size="sm" onclick={onClose} class="h-8 w-8 p-0 md:hidden" aria-label="Close sidebar">
        <X size={16} />
      </Button>
    </div>
  </div>
  <div class="flex flex-wrap items-center gap-2">
    <Popover.Root bind:open>
      <Popover.Trigger
        aria-label={triggerLabel}
        data-testid="chat-filter-trigger"
        class="inline-flex items-center gap-1.5 rounded px-1.5 py-0.5 text-xs hover:bg-muted focus-visible:outline focus-visible:outline-2 {activeCount >
        0
          ? 'text-foreground font-medium'
          : 'text-muted-foreground'}">
        <FunnelSimple size={12} weight={activeCount > 0 ? 'fill' : 'regular'} />
        <span>Filter</span>
        {#if activeCount > 0}<span class="text-muted-foreground">· {activeCount}</span>{/if}
        {#if !showHidden && hiddenAttentionCount > 0}
          <span
            class="ml-0.5 inline-flex min-w-4 items-center justify-center rounded-full bg-red-600 px-1 text-[10px] font-semibold leading-4 text-white"
            aria-hidden="true">{hiddenAttentionCount}</span>
        {/if}
      </Popover.Trigger>
      <Popover.Content align="start" class="w-64 max-w-[calc(100vw-2rem)] p-2" data-testid="chat-filter-menu">
        <div class="space-y-1 px-1 py-1">
          <label class="flex items-center gap-2 text-sm cursor-pointer hover:opacity-80">
            <input type="checkbox" checked={showArchived} onchange={onToggleArchived} class={checkboxClass} />
            <Archive size={14} class="text-muted-foreground" />
            <span>Archived</span>
          </label>
          {#if canSeeDeleted}
            <label
              title={deletedIsAdminOnly ? 'Site admins only' : undefined}
              class="flex items-center gap-2 text-sm cursor-pointer hover:opacity-80 {deletedIsAdminOnly
                ? ADMIN_ONLY_TEXT
                : ''}">
              <input type="checkbox" checked={showDeleted} onchange={onToggleDeleted} class={checkboxClass} />
              <Trash size={14} class="text-muted-foreground" />
              <span>Deleted</span>
            </label>
          {/if}
          <label class="flex items-center gap-2 text-sm cursor-pointer hover:opacity-80">
            <input type="checkbox" checked={showHidden} onchange={onToggleHidden} class={checkboxClass} />
            <EyeSlash size={14} class="text-muted-foreground" />
            <span>Hidden</span>
            {#if hiddenAttentionCount > 0}
              <span
                data-testid="hidden-attention-count"
                title={`${hiddenAttentionCount} hidden ${hiddenAttentionCount === 1 ? 'conversation is' : 'conversations are'} waiting on you`}
                class="ml-auto inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 text-xs font-semibold text-white"
                >{hiddenAttentionCount}</span>
            {/if}
          </label>
        </div>
        {#if visualTags.length > 0}
          <div class="my-2 h-px bg-border"></div>
          <p class="px-1 pb-1 text-xs text-muted-foreground">Only conversations tagged</p>
          <div class="max-h-64 overflow-y-auto">
            {#each visualTags as tag (tag.id)}
              <button
                type="button"
                aria-pressed={selectedTagId === tag.id}
                onclick={() => selectTag(tag)}
                class="flex w-full items-center gap-2 rounded px-1 py-1 text-left text-sm hover:bg-muted {selectedTagId ===
                tag.id
                  ? 'bg-muted font-medium'
                  : ''}">
                <VisualTagIcon icon={tag.icon} size={16} class={`shrink-0 ${visualTagColour(tag.colour)}`} />
                <span class="min-w-0 flex-1 truncate">{tag.label}</span>
                {#if tag.hides_from_list}<EyeSlash
                    size={12}
                    class="shrink-0 text-muted-foreground"
                    aria-label="Hidden from the list" />{/if}
                {#if selectedTagId === tag.id}<Check size={14} class="shrink-0" />{/if}
              </button>
            {/each}
          </div>
        {/if}
      </Popover.Content>
    </Popover.Root>
    {#if selectedTag}
      <button
        type="button"
        onclick={() => onSelectTag(null)}
        aria-label={`Stop showing only ${selectedTag.label}`}
        class="inline-flex items-center gap-1 rounded-full border border-border px-2 py-0.5 text-xs hover:bg-muted">
        <VisualTagIcon icon={selectedTag.icon} size={12} class={visualTagColour(selectedTag.colour)} />
        <span class="max-w-32 truncate">{selectedTag.label}</span>
        <X size={10} />
      </button>
    {/if}
  </div>
</header>
