<script>
  // A room page's history with a full recent window of resident messages,
  // for receipts that must move on older messages loaded by scrolling, and
  // must survive copies of the page serialized before they moved.
  import { createChatHistory } from '../app/frontend/lib/chat-history.svelte';
  import ChatMessageList from '../app/frontend/lib/components/chat/ChatMessageList.svelte';

  const snapshot = () =>
    Array.from({ length: 30 }, (_, i) => ({
      id: `recent-${i}`,
      content: `Recent ${i}`,
      role: 'assistant',
      author_name: 'Lume',
      agent_id: 'lume',
      completed: true,
      created_at: `2026-10-10T12:${String(10 + i).padStart(2, '0')}:00Z`,
      handoff_receipts:
        i === 29 ? [{ recipient_id: 'mira', recipient_name: 'Mira', state: 'queued', reason: null }] : [],
      handoff_receipts_version: i === 29 ? 10 : 0,
    }));
  let recent = $state(snapshot());
  const history = createChatHistory(() => ({
    chat: { id: 'room' },
    account: { id: 'account' },
    recent,
    hasMore: true,
    oldestId: 'recent-0',
    setRecent: (messages) => (recent = messages),
  }));
</script>

<button type="button" data-testid="load-older" onclick={() => history.loadMore()}>Load older</button>
<!-- What an Inertia reload serialized before the receipt moved delivers. -->
<button type="button" data-testid="stale-reload" onclick={() => (recent = snapshot())}>Stale reload</button>
<div style="height: 400px; display: flex; flex-direction: column;">
  <ChatMessageList
    bind:messagesContainer={history.container}
    allMessages={history.messages}
    visibleMessages={history.messages}
    chat={{ id: 'room', manual_responses: true }}
    isGroupChat={true}
    hasMore={history.hasMore}
    oldestId={history.oldestId}
    loadingMore={history.loading}
    handleScroll={history.handleScroll}
    loadMoreMessages={history.loadMore} />
</div>
