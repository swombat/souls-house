<script>
  import { Link, page } from '@inertiajs/svelte';
  import { accountChatPath, accountChatDiscardPath } from '@/routes';
  import { commitmentMarkLabel, handoffStuckLabel, shortDate } from '$lib/chat-display';
  import ChatParticipantAvatars from '$lib/components/chat/ChatParticipantAvatars.svelte';
  import { Alarm, Archive, ChatText, HandPalm, PushPin, Spinner, Trash } from 'phosphor-svelte';
  import ChatRowActions from './ChatRowActions.svelte';
  import ReplyAttentionEye from './ReplyAttentionEye.svelte';
  import VisualTagPicker from './VisualTagPicker.svelte';
  import WorkStatusIcon from './WorkStatusIcon.svelte';
  import WorkStatusSummary from './WorkStatusSummary.svelte';
  import { workStatusDescription } from '$lib/work-status';

  let { chat, accountId, activeChatId = null, visualTags = [], rooms = [], filterParams = {} } = $props();
  const chatPath = $derived(
    accountChatPath(accountId, chat.id, {
      room: $page.props.current_room === 'all' ? 'all' : undefined,
      ...filterParams,
    })
  );
  const commitmentLabel = $derived(commitmentMarkLabel(chat.next_commitment));
  const stuckLabel = $derived(handoffStuckLabel(chat.handoff_stuck));
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
      href={chatPath}
      aria-current={activeChatId === chat.id ? 'page' : undefined}
      class="block p-3 pr-10 hover:bg-muted/50 transition-colors border-b border-border
         {activeChatId === chat.id ? 'bg-primary/10 border-l-4 border-l-primary' : ''}
         {chat.archived ? 'opacity-50' : ''}">
      <div class="pl-8 font-medium text-sm truncate flex items-center gap-2 md:pr-7">
        {#if chat.archived}
          <Archive size={12} class="text-muted-foreground flex-shrink-0" />
        {/if}
        <span class="truncate">{chat.title_or_default || chat.title || 'New Chat'}</span>
        {#if !chat.title && chat.message_count > 0}
          <Spinner size={12} class="animate-spin text-muted-foreground flex-shrink-0" />
        {/if}
      </div>
      {#if chat.work_status?.state}
        <div class="pl-8 pt-1 pb-1">
          <WorkStatusSummary status={chat.work_status} compact showIcon={false} />
        </div>
      {/if}
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
      {#if chat.work_status?.state}
        <span
          class="inline-flex h-8 w-8 items-center justify-center"
          role="img"
          aria-label={workStatusDescription(chat.work_status)}>
          <WorkStatusIcon state={chat.work_status.state} />
        </span>
      {:else}
        <VisualTagPicker {chat} {accountId} tags={visualTags} {commitmentLabel} {stuckLabel} />
      {/if}
    </div>
    <div class="absolute right-2 top-2 flex items-center gap-1">
      <!-- Desktop only, on hover or keyboard focus; on a phone the conversation menu does this. -->
      <span
        data-row-actions
        class="relative hidden md:inline-flex md:opacity-0 md:group-hover/card:opacity-100 md:focus-within:opacity-100 md:has-[[data-state=open]]:opacity-100 transition-opacity">
        <ChatRowActions {chat} {accountId} {rooms} />
      </span>
      <ReplyAttentionEye chatId={chat.id} {accountId} badge={Boolean(chat.work_status?.state)} />
    </div>
    {#if chat.work_status?.state && (chat.visual_tag?.pins_to_top || stuckLabel || commitmentLabel)}
      <div class="absolute left-3 bottom-2 flex items-center gap-1">
        {#if chat.visual_tag?.pins_to_top}
          <span title="Pinned by visual tag" aria-label="Pinned by visual tag" role="img"><PushPin size={12} /></span>
        {/if}
        {#if stuckLabel}
          <span
            title={stuckLabel}
            aria-label={stuckLabel}
            role="img"
            data-testid="handoff-stuck-mark"
            class="text-red-600"><HandPalm size={12} /></span>
        {:else if commitmentLabel}
          <span
            title={commitmentLabel}
            aria-label={commitmentLabel}
            role="img"
            data-testid="commitment-mark"
            class="text-muted-foreground"><Alarm size={12} /></span>
        {/if}
      </div>
    {/if}
  {/if}
</div>
