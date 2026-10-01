<script>
  import { createChatHistory } from '../app/frontend/lib/chat-history.svelte';
  let { id = 'first', count = 100 } = $props();
  let messages = $derived(Array.from({ length: count }, (_, i) => ({ id: `${id}-${i}`, content: `Message ${i}` })));
  const history = createChatHistory(() => ({
    chat: { id },
    account: { id: 'account' },
    recent: messages,
    hasMore: true,
    oldestId: 'oldest',
    setRecent: () => {},
  }));
</script>

<div
  data-testid="history"
  bind:this={history.container}
  onscroll={history.handleScroll}
  style="height: 400px; overflow: auto; scroll-behavior: smooth;">
  <div data-testid="content">
    {#each history.messages as message (message.id)}
      <p style="height: 50px; margin: 0;">{message.content}</p>
    {/each}
  </div>
</div>
