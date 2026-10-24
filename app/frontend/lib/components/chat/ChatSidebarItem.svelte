<script>
  import { Link, page } from '@inertiajs/svelte';
  import { accountChatPath, accountChatDiscardPath } from '@/routes';
  import { shortDate } from '$lib/chat-display';
  import ChatParticipantAvatars from '$lib/components/chat/ChatParticipantAvatars.svelte';
  import { Archive, ChatText, Spinner, Trash } from 'phosphor-svelte';
  import ChatRoomMover from './ChatRoomMover.svelte';
  import ReplyAttentionEye from './ReplyAttentionEye.svelte';
  import VisualTagPicker from './VisualTagPicker.svelte';

  let { chat, accountId, activeChatId = null, visualTags = [], rooms = [] } = $props();
  // Moving needs somewhere to go: Main plus at least one room.
  const canMove = $derived(rooms.length > 0);
</script>

<div class="relative group/card">
  {#if chat.discarded}
    <div class="p-3 border-b border-border flex items-center gap-2">
      <Trash size={14} class="text-muted-foreground shrink-0" />
      <span class="text-sm text-muted-foreground truncate flex-1">
        {chat.title_or_default || chat.title || 'New Chat'}
      </span>
      <Link
        href={accountChatDiscardPath(accountId, chat.id)}
        method="delete"
        as="button"
        preserveScroll
        class="text-sm underline"
        aria-label={`Restore ${chat.title_or_default || chat.title || 'conversation'}`}>
        Restore
      </Link>
    </div>
  {:else}
    <Link
      href={accountChatPath(accountId, chat.id) + ($page.props.current_room === 'all' ? '?room=all' : '')}
      aria-current={activeChatId === chat.id ? 'page' : undefined}
      class="block p-3 pr-10 hover:bg-muted/50 transition-colors border-b border-border
         {activeChatId === chat.id ? 'bg-primary/10 border-l-4 border-l-primary' : ''}
         {chat.archived ? 'opacity-50' : ''}">
      <div class="pl-8 font-medium text-sm truncate flex items-center gap-2 {canMove ? 'md:pr-7' : ''}">
        {#if chat.archived}
          <Archive size={12} class="text-muted-foreground flex-shrink-0" />
        {/if}
        <span class="truncate">{chat.title_or_default || chat.title || 'New Chat'}</span>
        {#if !chat.title && chat.message_count > 0}
          <Spinner size={12} class="animate-spin text-muted-foreground flex-shrink-0" />
        {/if}
      </div>
      <div class="flex items-center gap-2 w-full group">
        {#if chat.manual_responses && chat.participants_json?.length > 0}
          <ChatParticipantAvatars participants={chat.participants_json} workingAgentIds={chat.working_agent_ids} />
        {:else}
          <div class="text-xs text-muted-foreground flex-1/3 hidden group-hover:block">
            {chat.model_label}
          </div>
        {/if}
        <div class="text-xs text-muted-foreground flex-1/3 flex items-end justify-end hidden group-hover:block">
          {shortDate(chat.activity_at)}
        </div>
        <div class="text-xs text-muted-foreground flex-1/3 flex items-end justify-end gap-2">
          {#if chat.context_tokens > 0}
            <span class="hidden group-hover:inline">{Math.round(chat.context_tokens / 1000)}k</span>
          {/if}
          <span class="flex items-center gap-1">
            <ChatText size={12} />
            {chat.message_count}
          </span>
        </div>
      </div>
    </Link>
    <div class="absolute left-2 top-1.5">
      <VisualTagPicker {chat} {accountId} tags={visualTags} />
    </div>
    <div class="absolute right-2 top-2 flex items-center gap-1">
      {#if canMove}
        <!-- Desktop only, on hover or keyboard focus; on a phone the conversation menu moves it. -->
        <span
          data-room-mover
          class="relative hidden md:inline-flex md:opacity-0 md:group-hover/card:opacity-100 md:focus-within:opacity-100 md:has-[[data-state=open]]:opacity-100 transition-opacity">
          <ChatRoomMover {chat} {accountId} {rooms} />
        </span>
      {/if}
      <ReplyAttentionEye chatId={chat.id} {accountId} />
    </div>
  {/if}
</div>
