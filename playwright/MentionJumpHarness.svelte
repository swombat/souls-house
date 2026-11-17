<script>
  import { page } from '@inertiajs/svelte';
  import { createChatHistory } from '../app/frontend/lib/chat-history.svelte';
  import ChatMessageList from '../app/frontend/lib/components/chat/ChatMessageList.svelte';
  import MentionJumpButton from '../app/frontend/lib/components/chat/MentionJumpButton.svelte';

  // Recent window m30..m59; older pages come from the test's route.
  let { flagged = [] } = $props();
  page.set({
    props: { reply_attention: { messages: flagged, chats: {}, through_messages: {} }, flash: {}, errors: {} },
    component: 'chats/show',
    url: '/accounts/account/chats/chat',
    version: 'test',
  });
  const recent = Array.from({ length: 30 }, (_, i) => ({
    id: `m${i + 30}`,
    content: `Message ${i + 30}`,
    role: 'user',
    created_at: '2026-10-01T07:00:00Z',
  }));
  const history = createChatHistory(() => ({
    chat: { id: 'chat' },
    account: { id: 'account' },
    recent,
    hasMore: true,
    oldestId: 'm30',
    setRecent: () => {},
  }));
</script>

<div style="height: 400px; display: flex; flex-direction: column; position: relative;">
  <ChatMessageList
    accountId="account"
    bind:messagesContainer={history.container}
    allMessages={history.messages}
    visibleMessages={history.messages}
    chat={{ id: 'chat' }}
    hasMore={history.hasMore}
    oldestId={history.oldestId}
    loadingMore={history.loading}
    handleScroll={history.handleScroll}
    loadMoreMessages={history.loadMore} />
  <MentionJumpButton chatId="chat" reveal={history.reveal} />
</div>
