<script>
  // The Actions menu beside Filter: whatever the list shows right now (this
  // room, this filter), marked read or tagged in one request each. The server
  // does the work in a fixed number of queries (ConversationBulk); the list
  // then refreshes like any single change.
  import * as Popover from '$lib/components/shadcn/popover/index.js';
  import { Checks, Lightning, Tag, X } from 'phosphor-svelte';
  import VisualTagIcon from './VisualTagIcon.svelte';
  import { visualTagColour } from '$lib/visual-tags';
  import { reloadProps } from '$lib/cable';

  let { accountId, chatIds = [], unreadChatIds = [], visualTags = [] } = $props();

  let open = $state(false);
  let busy = $state(false);
  let error = $state('');

  const count = $derived(chatIds.length);
  const plural = (n) => `${n} ${n === 1 ? 'conversation' : 'conversations'}`;

  async function send(method, path, body) {
    busy = true;
    error = '';
    try {
      const response = await fetch(`/accounts/${accountId}/chats/bulk/${path}`, {
        method,
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        body: JSON.stringify(body),
      });
      if (!response.ok) {
        const data = await response.json().catch(() => ({}));
        error = data.error || 'That did not work. Please try again.';
        return false;
      }
      open = false;
      return true;
    } catch {
      error = 'That did not work. Please try again.';
      return false;
    } finally {
      busy = false;
      // The account broadcast refreshes these too; asking covers a dropped socket.
      reloadProps(['chats', 'visual_tags', 'reply_attention']);
    }
  }

  function markAllRead() {
    if (unreadChatIds.length === 0) return;
    send('POST', 'mark_read', { conversation_ids: unreadChatIds });
  }

  function tagAll(tag) {
    if (count === 0) return;
    const what = tag ? `Tag ${plural(count)} as ${tag.label}?` : `Remove the tag from ${plural(count)}?`;
    if (!window.confirm(`${what} Each one records the change in its transcript.`)) return;
    send('PATCH', 'visual_tag', { conversation_ids: chatIds, visual_tag_id: tag ? tag.id : null });
  }
</script>

<Popover.Root bind:open>
  <Popover.Trigger
    aria-label="Actions on the conversations in this list"
    data-testid="chat-bulk-actions-trigger"
    disabled={count === 0}
    class="inline-flex items-center gap-1.5 rounded px-1.5 py-0.5 text-xs text-muted-foreground hover:bg-muted focus-visible:outline focus-visible:outline-2 disabled:opacity-50">
    <Lightning size={12} />
    <span>Actions</span>
  </Popover.Trigger>
  <Popover.Content align="start" class="w-64 max-w-[calc(100vw-2rem)] p-2" data-testid="chat-bulk-actions-menu">
    <p class="px-1 pb-1 text-xs text-muted-foreground">All {plural(count)} in this list</p>
    <button
      type="button"
      data-testid="chat-bulk-mark-read"
      disabled={busy || unreadChatIds.length === 0}
      onclick={markAllRead}
      class="flex w-full items-center gap-2 rounded px-1 py-1 text-left text-sm hover:bg-muted disabled:opacity-50 disabled:hover:bg-transparent">
      <Checks size={16} class="shrink-0 text-muted-foreground" />
      <span class="min-w-0 flex-1">Mark all as read</span>
      {#if unreadChatIds.length > 0}
        <span class="text-xs text-muted-foreground">{unreadChatIds.length}</span>
      {/if}
    </button>
    {#if visualTags.length > 0}
      <div class="my-2 h-px bg-border"></div>
      <p class="flex items-center gap-1 px-1 pb-1 text-xs text-muted-foreground"><Tag size={12} /> Tag them all</p>
      <div class="max-h-64 overflow-y-auto" data-testid="chat-bulk-tag-list">
        {#each visualTags as tag (tag.id)}
          <button
            type="button"
            disabled={busy}
            onclick={() => tagAll(tag)}
            class="flex w-full items-center gap-2 rounded px-1 py-1 text-left text-sm hover:bg-muted disabled:opacity-50">
            <VisualTagIcon icon={tag.icon} size={16} class={`shrink-0 ${visualTagColour(tag.colour)}`} />
            <span class="min-w-0 flex-1 truncate">{tag.label}</span>
          </button>
        {/each}
        <button
          type="button"
          disabled={busy}
          onclick={() => tagAll(null)}
          class="flex w-full items-center gap-2 rounded px-1 py-1 text-left text-sm text-muted-foreground hover:bg-muted disabled:opacity-50">
          <X size={16} class="shrink-0" />
          <span class="min-w-0 flex-1">Remove tag</span>
        </button>
      </div>
    {/if}
    {#if error}
      <p class="px-1 pt-2 text-xs text-red-600" role="alert">{error}</p>
    {/if}
  </Popover.Content>
</Popover.Root>
