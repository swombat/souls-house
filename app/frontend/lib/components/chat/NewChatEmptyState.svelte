<script>
  import { Link } from '@inertiajs/svelte';
  import { accountChatPath } from '@/routes';

  let { chats = [], accountId } = $props();
  const recentChats = $derived(
    chats
      .filter((chat) => !chat.archived && !chat.discarded)
      .toSorted((a, b) => new Date(b.updated_at) - new Date(a.updated_at))
      .slice(0, 3)
  );
</script>

<div class="flex-1 min-h-0 overflow-y-auto flex items-center justify-center px-4 md:px-6 py-4">
  <div class="text-center text-muted-foreground max-w-md">
    <h2 class="text-xl font-semibold mb-2">Start a new conversation</h2>
    <p>Select one or more residents above and type your first message below to begin.</p>
    {#if recentChats.length > 0}
      <nav aria-label="Recent conversations" class="md:hidden mt-6">
        <p>Or you can select a recent conversation and jump straight to it:</p>
        <ul class="mt-3 space-y-2">
          {#each recentChats as chat (chat.id)}
            <li>
              <Link
                href={accountChatPath(accountId, chat.id)}
                class="block rounded-md border border-border px-3 py-3 text-foreground hover:bg-accent break-words">
                {chat.title_or_default || chat.title || 'New Conversation'}
              </Link>
            </li>
          {/each}
        </ul>
      </nav>
    {/if}
  </div>
</div>
