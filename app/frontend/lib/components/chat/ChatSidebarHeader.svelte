<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Archive, Plus, Trash, X } from 'phosphor-svelte';
  import RoomSwitcher from './RoomSwitcher.svelte';
  import { ADMIN_ONLY_TEXT } from '$lib/admin-only.js';

  let {
    accountId,
    hasRooms = false,
    canSeeDeleted = false,
    deletedIsAdminOnly = false,
    showArchived = false,
    showDeleted = false,
    onCreate,
    onClose,
    onToggleArchived,
    onToggleDeleted,
  } = $props();
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
  <div class="flex flex-wrap items-center gap-3">
    <label
      class="flex items-center gap-1.5 text-xs text-muted-foreground cursor-pointer hover:opacity-80 transition-opacity">
      <input
        type="checkbox"
        checked={showArchived}
        onchange={onToggleArchived}
        class="w-3 h-3 rounded border-gray-300 text-primary focus:ring-primary focus:ring-offset-0 focus:ring-1 transition-colors cursor-pointer" />
      <Archive size={12} />
      <span>Archived</span>
    </label>
    {#if canSeeDeleted}
      <label
        title={deletedIsAdminOnly ? 'Site admins only' : undefined}
        class="flex items-center gap-1.5 text-xs cursor-pointer hover:opacity-80 transition-opacity {deletedIsAdminOnly
          ? ADMIN_ONLY_TEXT
          : 'text-muted-foreground'}">
        <input
          type="checkbox"
          checked={showDeleted}
          onchange={onToggleDeleted}
          class="w-3 h-3 rounded border-gray-300 text-primary focus:ring-primary focus:ring-offset-0 focus:ring-1 transition-colors cursor-pointer" />
        <Trash size={12} />
        <span>Deleted</span>
      </label>
    {/if}
  </div>
</header>
