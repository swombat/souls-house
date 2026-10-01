<script>
  import { router, page } from '@inertiajs/svelte';
  import { newAccountChatPath } from '@/routes';
  import { createDynamicSync } from '$lib/use-sync';
  import ChatSidebarEmptyState from '$lib/components/chat/ChatSidebarEmptyState.svelte';
  import ChatSidebarHeader from '$lib/components/chat/ChatSidebarHeader.svelte';
  import ChatSidebarItem from '$lib/components/chat/ChatSidebarItem.svelte';

  let { chats = [], activeChatId = null, accountId, isOpen = false, onClose = () => {} } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ [`Account:${accountId}`]: 'chats' });
  });

  // Check if user can see deleted chats
  const canSeeDeleted = $derived($page.props.is_account_admin || $page.props.user?.site_admin);

  // Show deleted toggle state
  let showDeleted = $state(
    typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get('show_deleted') === 'true' : false
  );

  function toggleShowDeleted() {
    showDeleted = !showDeleted;
    const url = new URL(window.location.href);
    if (showDeleted) {
      url.searchParams.set('show_deleted', 'true');
    } else {
      url.searchParams.delete('show_deleted');
    }
    router.visit(url.toString(), { preserveState: true });
  }

  function createNewChat() {
    router.visit(newAccountChatPath(accountId));
  }
</script>

<!-- Mobile overlay -->
{#if isOpen}
  <button class="fixed inset-0 bg-black/50 z-40 md:hidden" onclick={onClose} aria-label="Close sidebar"></button>
{/if}

<aside
  class="w-80 border-r border-border bg-card flex flex-col
              fixed inset-y-0 left-0 z-50 transform transition-transform duration-200 ease-in-out
              md:relative md:translate-x-0 md:z-auto
              {isOpen ? 'translate-x-0' : '-translate-x-full'}">
  <ChatSidebarHeader
    {canSeeDeleted}
    {showDeleted}
    onCreate={createNewChat}
    {onClose}
    onToggleDeleted={toggleShowDeleted} />

  <div class="flex-1 overflow-y-auto">
    {#if chats.length === 0}
      <ChatSidebarEmptyState />
    {:else}
      <nav>
        {#each chats as chat (chat.id)}
          <ChatSidebarItem {chat} {accountId} {activeChatId} />
        {/each}
      </nav>
    {/if}
  </div>
</aside>
