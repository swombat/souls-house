<script>
  import { Link } from '@inertiajs/svelte';
  import { accountChatPath } from '@/routes';
  import { shortDate } from '$lib/chat-display';
  import ChatParticipantAvatars from '$lib/components/chat/ChatParticipantAvatars.svelte';
  import { Archive, ChatText, Spinner, Trash } from 'phosphor-svelte';
  import ReplyAttentionEye from './ReplyAttentionEye.svelte';

  let { chat, accountId, activeChatId = null } = $props();
</script>

<Link
  href={accountChatPath(accountId, chat.id)}
  class="block p-3 hover:bg-muted/50 transition-colors border-b border-border
         {activeChatId === chat.id ? 'bg-primary/10 border-l-4 border-l-primary' : ''}
         {chat.archived ? 'opacity-50' : ''}
         {chat.discarded ? 'opacity-40' : ''}">
  <div
    class="font-medium text-sm truncate flex items-center gap-2 {chat.discarded
      ? 'line-through text-red-600 dark:text-red-400'
      : ''}">
    {#if chat.archived && !chat.discarded}
      <Archive size={12} class="text-muted-foreground flex-shrink-0" />
    {/if}
    {#if chat.discarded}
      <Trash size={12} class="text-red-500 flex-shrink-0" />
    {/if}
    <span class="truncate">{chat.title_or_default || chat.title || 'New Chat'}</span>
    <ReplyAttentionEye chatId={chat.id} />
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
