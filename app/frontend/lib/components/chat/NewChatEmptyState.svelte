<script>
  import { tick, untrack } from 'svelte';
  import { Link, page } from '@inertiajs/svelte';
  import { accountChatPath } from '@/routes';
  import ReplyAttentionEye from './ReplyAttentionEye.svelte';
  import RoomWorkingSpinner from './RoomWorkingSpinner.svelte';
  import VisualTagPicker from './VisualTagPicker.svelte';

  // On a phone, offer as many recent conversations as fit on the screen,
  // up to MAX_RECENT. One that would be cut off is not shown at all.
  const MAX_RECENT = 10;

  let { chats = [], accountId } = $props();
  const recentChats = $derived(
    chats
      .filter((chat) => !chat.archived && !chat.discarded)
      .toSorted((a, b) => new Date(b.activity_at) - new Date(a.activity_at))
      .slice(0, MAX_RECENT)
  );

  let scroller = $state();
  let list = $state();
  let fitCount = $state(MAX_RECENT);
  const shownChats = $derived(recentChats.slice(0, fitCount));

  // Lay out every candidate, then keep the ones whose bottom edge is inside
  // the scroller. Hiding the rest never moves the ones above, so one pass is
  // enough. If not even the newest fits whole, show none, and no prompt.
  async function measure() {
    if (!scroller) return;
    fitCount = MAX_RECENT;
    await tick();
    if (!list || !list.offsetParent) return;
    const style = getComputedStyle(scroller);
    const bottom = scroller.getBoundingClientRect().bottom - (parseFloat(style.paddingBottom) || 0);
    let fits = 0;
    for (const item of list.children) {
      if (item.getBoundingClientRect().bottom > bottom + 0.5) break;
      fits += 1;
    }
    fitCount = fits;
  }

  $effect(() => {
    recentChats;
    untrack(() => measure());
  });

  $effect(() => {
    if (!scroller || typeof ResizeObserver === 'undefined') return;
    // Some page tests swap in a ResizeObserver without methods.
    const observer = new ResizeObserver(() => measure());
    observer?.observe?.(scroller);
    return () => observer?.disconnect?.();
  });

  // Residents working in a conversation, as the spinner wants them.
  function workingIn(chat) {
    const ids = chat.working_agent_ids || [];
    const agents = (chat.participants_json || []).filter((p) => p.type === 'agent');
    return ids.map((id) => agents.find((a) => a.id === id)).filter(Boolean);
  }
</script>

<div
  bind:this={scroller}
  data-testid="new-chat-empty-state"
  class="flex-1 min-h-0 overflow-y-auto flex items-start md:items-center justify-center px-4 md:px-6 py-4">
  <div class="w-full text-center text-muted-foreground max-w-md">
    <h2 class="hidden md:block text-xl font-semibold">Start a new conversation</h2>
    {#if shownChats.length > 0}
      <nav aria-label="Recent conversations" class="md:hidden">
        <p>Or pick an existing conversation:</p>
        <ul bind:this={list} class="mt-3 space-y-2">
          {#each shownChats as chat (chat.id)}
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
