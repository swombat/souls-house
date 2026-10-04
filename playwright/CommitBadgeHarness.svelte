<script>
  import { page } from '@inertiajs/svelte';
  import MessageBubble from '../app/frontend/lib/components/chat/MessageBubble.svelte';

  let { messages = [], siteAdmin = true } = $props();

  page.update((current) => ({ ...current, props: { ...current.props, user: { site_admin: siteAdmin } } }));
</script>

<div class="p-4 space-y-4 max-w-2xl">
  {#each messages as message (message.id)}
    <MessageBubble {message} />
  {/each}
</div>
