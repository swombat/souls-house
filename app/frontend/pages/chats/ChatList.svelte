<script>
  import { router, page } from '@inertiajs/svelte';
  import { newAccountChatPath } from '@/routes';
  import { createDynamicSync } from '$lib/use-sync';
  import ChatSidebarEmptyState from '$lib/components/chat/ChatSidebarEmptyState.svelte';
  import ChatSidebarHeader from '$lib/components/chat/ChatSidebarHeader.svelte';
  import ChatSidebarItem from '$lib/components/chat/ChatSidebarItem.svelte';
  import { keepSidebarScroll } from '$lib/sidebar-scroll';

  let { chats = [], activeChatId = null, accountId, isOpen = false, onClose = () => {} } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ [`Account:${accountId}`]: ['chats', 'hidden_chat_ids', 'visual_tags', 'rooms', 'current_room'] });
  });

  const scrollKey = $derived(`${accountId}:${$page.props.current_room || ''}`);

  const hasRooms = $derived(($page.props.rooms || []).length > 0);

  // Check if user can see deleted chats
  const canSeeDeleted = $derived($page.props.is_account_admin || $page.props.user?.site_admin);
  // Red when the toggle is there only because the viewer is a site admin: every
  // confirmed member gets it, and is_account_admin already includes site admins.
  const deletedIsAdminOnly = $derived(!!$page.props.viewing_as_site_admin);

  const urlParams = $derived(new URLSearchParams($page.url.split('?')[1] || ''));
  const showArchived = $derived(urlParams.get('show_archived') === 'true');
  const showHidden = $derived(urlParams.get('show_hidden') === 'true');
  const selectedTagId = $derived(urlParams.get('tag') || null);
  const selectedWorkStatus = $derived(urlParams.get('work_status') || '');
  const workReplied = $derived(urlParams.get('work_replied') === 'true');
  // Hidden conversations with an open red eye: the server sends only their
  // IDs, so the count follows both the tags and the eyes as they change.
  const hiddenAttentionCount = $derived(
    ($page.props.hidden_chat_ids || []).filter((id) => $page.props.reply_attention?.chats?.[id] > 0).length
  );
  // Carried on each conversation link so opening one keeps the filter.
  const filterParams = $derived({
    show_archived: showArchived ? true : undefined,
    show_hidden: showHidden ? true : undefined,
    tag: selectedTagId || undefined,
    work_status: selectedWorkStatus || undefined,
    work_replied: workReplied ? true : undefined,
  });

  function visitWithParam(name, value) {
    const url = new URL(window.location.href);
    if (value) {
      url.searchParams.set(name, value);
    } else {
      url.searchParams.delete(name);
    }
    router.visit(url.toString(), { preserveState: true });
  }

  function toggleShowHidden() {
    visitWithParam('show_hidden', showHidden ? null : 'true');
  }

  function selectTag(tagId) {
    visitWithParam('tag', tagId);
  }

  function toggleShowArchived() {
    const url = new URL(window.location.href);
    if (showArchived) {
      url.searchParams.delete('show_archived');
    } else {
      url.searchParams.set('show_archived', 'true');
    }
    router.visit(url.toString(), { preserveState: true });
  }

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
    {accountId}
    {hasRooms}
    {canSeeDeleted}
    {deletedIsAdminOnly}
    {showArchived}
    {showDeleted}
    {showHidden}
    {hiddenAttentionCount}
    {selectedTagId}
    {selectedWorkStatus}
    {workReplied}
    onSelectWorkStatus={(state) => visitWithParam('work_status', state)}
    onToggleWorkReplied={() => visitWithParam('work_replied', workReplied ? null : 'true')}
    visualTags={$page.props.visual_tags || []}
    onToggleHidden={toggleShowHidden}
    onSelectTag={selectTag}
    onCreate={createNewChat}
    {onClose}
    onToggleArchived={toggleShowArchived}
    onToggleDeleted={toggleShowDeleted} />

  <div class="flex-1 overflow-y-auto" data-chat-sidebar-scroller use:keepSidebarScroll={scrollKey}>
    {#if chats.length === 0}
      <ChatSidebarEmptyState />
    {:else}
      <nav>
        {#each chats as chat (chat.id)}
          <ChatSidebarItem
            {chat}
            {accountId}
            {activeChatId}
            {filterParams}
            visualTags={$page.props.visual_tags || []}
            rooms={$page.props.rooms || []} />
        {/each}
      </nav>
    {/if}
  </div>
</aside>
