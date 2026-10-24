<script>
  import { Link, page } from '@inertiajs/svelte';
  import { accountChatPath } from '@/routes';
  import ReplyAttentionEye from './ReplyAttentionEye.svelte';
  import RoomWorkingSpinner from './RoomWorkingSpinner.svelte';
  import VisualTagPicker from './VisualTagPicker.svelte';

  let { chats = [], accountId } = $props();
  const recentChats = $derived(
    chats
      .filter((chat) => !chat.archived && !chat.discarded)
      .toSorted((a, b) => new Date(b.activity_at) - new Date(a.activity_at))
      .slice(0, 3)
  );

  // Residents working in a conversation, as the spinner wants them.
  function workingIn(chat) {
    const ids = chat.working_agent_ids || [];
    const agents = (chat.participants_json || []).filter((p) => p.type === 'agent');
    return ids.map((id) => agents.find((a) => a.id === id)).filter(Boolean);
  }
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
            {@const working = workingIn(chat)}
            <li class="relative">
              <Link
                href={accountChatPath(accountId, chat.id)}
                class="block rounded-md border border-border pl-11 {working.length ? 'pr-20' : 'pr-10'} py-3 text-foreground hover:bg-accent break-words">
                {chat.title_or_default || chat.title || 'New Conversation'}
              </Link>
              <div class="absolute left-2 top-2">
                <VisualTagPicker {chat} {accountId} tags={$page.props.visual_tags || []} />
              </div>
              <div class="absolute right-2 top-2 flex items-center gap-1">
                {#if working.length}
                  <span class="pointer-events-none flex size-8 items-center justify-center">
                    <RoomWorkingSpinner agents={working} />
                  </span>
                {/if}
                <ReplyAttentionEye chatId={chat.id} {accountId} />
              </div>
            </li>
          {/each}
        </ul>
      </nav>
    {/if}
  </div>
</div>
