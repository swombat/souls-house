<script>
  import { createChatHistory } from '../app/frontend/lib/chat-history.svelte';
  import ChatMessageList from '../app/frontend/lib/components/chat/ChatMessageList.svelte';
  let { id = 'first', count = 30 } = $props();
  let messages = $derived(
    Array.from({ length: count }, (_, i) => ({
      id: `${id}-${i}`,
      content: `Message ${i}`,
      role: 'user',
      created_at: '2026-10-01T07:00:00Z',
    }))
  );
  const history = createChatHistory(() => ({
    chat: { id },
    account: { id: 'account' },
    recent: messages,
    hasMore: true,
    oldestId: 'oldest',
    setRecent: () => {},
  }));
</script>

<div style="height: 400px; display: flex; flex-direction: column;">
  <ChatMessageList
    bind:messagesContainer={history.container}
    allMessages={history.messages}
    visibleMessages={history.messages}
    chat={{ id }}
    hasMore={history.hasMore}
    oldestId={history.oldestId}
    loadingMore={history.loading}
    handleScroll={history.handleScroll}
    loadMoreMessages={history.loadMore} />
</div>
