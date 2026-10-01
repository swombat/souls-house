<script>
  import { createChatHistory } from '$lib/chat-history.svelte';
  import { createChatResponse } from '$lib/chat-response.svelte';
  let { chat, messages = [], hasMore = true, oldestId = 'recent' } = $props();
  export const history = createChatHistory(() => ({
    account: { id: 'account' },
    chat,
    recent: messages,
    hasMore,
    oldestId,
    setRecent: (value) => (messages = value),
  }));
  export const response = createChatResponse(() => ({ chat, messages: history.messages }));
</script>

<div bind:this={history.container} onscroll={history.handleScroll}>
  {#each history.messages as message (message.id)}
    <p>{message.content}</p>
  {/each}
</div>
