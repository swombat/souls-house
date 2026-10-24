<script>
  import { page } from '@inertiajs/svelte';
  import ChatSidebarItem from '../app/frontend/lib/components/chat/ChatSidebarItem.svelte';

  let { chats = [], rooms = [], waiting = {} } = $props();

  page.set({
    props: {
      rooms,
      current_room: 'main',
      main_room_name: 'Main',
      reply_attention: { chats: waiting, through_messages: {}, rooms: {} },
      flash: {},
      errors: {},
    },
    component: 'chats/index',
    url: '/accounts/acc/chats',
    version: 'test',
  });
</script>

<aside class="w-80 border-r border-border bg-card" data-testid="chat-list">
  <nav>
    {#each chats as chat (chat.id)}
      <ChatSidebarItem {chat} accountId="acc" {rooms} />
    {/each}
  </nav>
</aside>
