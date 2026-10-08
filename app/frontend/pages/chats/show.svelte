<script>
  import { page } from '@inertiajs/svelte';
  import { mode } from 'mode-watcher';
  import { createDynamicSync } from '$lib/use-sync';
  import { buildChatSubscriptions, chatSyncSignature } from '$lib/chat-sync-subscriptions';
  import { tokenWarningLevel as getTokenWarningLevel } from '$lib/chat-utils';
  import { lastMessageIsHiddenThinking, visibleChatMessages } from '$lib/chat-message-state';
  import { createChatHistory } from '$lib/chat-history.svelte';
  import { createChatRuntimeActivity } from '$lib/chat-runtime-activity.svelte';
  import { createChatResponse } from '$lib/chat-response.svelte';
  import { createChatActions } from '$lib/chat-actions.svelte';
  import ChatList from './ChatList.svelte';
  import ChatHeader from '$lib/components/chat/ChatHeader.svelte';
  import TokenWarningBanner from '$lib/components/chat/TokenWarningBanner.svelte';
  import ChatMessageList from '$lib/components/chat/ChatMessageList.svelte';
  import ChatInputArea from '$lib/components/chat/ChatInputArea.svelte';
  import TelegramBanner from '$lib/components/chat/TelegramBanner.svelte';
  import ChatDebug from '$lib/components/chat/chat-debug.svelte';
  import ChatOverlays from '$lib/components/chat/ChatOverlays.svelte';
  import ConversationCostDrawer from '$lib/components/chat/ConversationCostDrawer.svelte';

  let {
    chat,
    chats = [],
    messages: recentMessages = [],
    runtime_interactions: initialRuntimeInteractions = [],
    cost_breakdown: costBreakdown = {},
    has_more_messages: serverHasMore = false,
    oldest_message_id: serverOldestId = null,
    account,
    agents = [],
    available_agents = [],
    addable_agents = [],
    show_usage_in_chat: showUsageInChat = false,
    file_upload_config = {},
    telegram_deep_link: telegramDeepLink = null,
  } = $props();
  let showAllMessages = $state(false);
  let debugMode = $state(false);
  let showCosts = $state(false);
  let showMessageTelemetry = $state(false);
  let sidebarOpen = $state(false);
  let previousChatId;
  const shikiTheme = $derived(mode.current === 'dark' ? 'catppuccin-mocha' : 'catppuccin-latte');
  const isSiteAdmin = $derived($page.props.user?.site_admin ?? false);
  const thresholds = $derived($page.props.token_thresholds || { amber: 100_000, red: 150_000, critical: 200_000 });
  const contextTokens = $derived(chat?.context_tokens || 0);
  const costTokens = $derived(chat?.cost_tokens || { input: 0, output: 0 });
  const tokenWarningLevel = $derived(getTokenWarningLevel(contextTokens, thresholds));

  const history = createChatHistory(() => ({
    account,
    chat,
    recent: recentMessages,
    hasMore: serverHasMore,
    oldestId: serverOldestId,
    setRecent: (messages) => (recentMessages = messages),
  }));
  const activity = createChatRuntimeActivity(() => ({ account, chat, initial: initialRuntimeInteractions }));
  const response = createChatResponse(() => ({ chat, messages: history.messages }));
  const actions = createChatActions(() => ({ account, chat }), history);
  const visibleMessages = $derived(visibleChatMessages(history.messages, showAllMessages));
  const activeRuntimeAgentIds = $derived(activity.rows.filter((row) => row.active).map((row) => row.agent_id));
  const agentIsResponding = $derived(activeRuntimeAgentIds.length > 0);
  const responseMarker = $derived(
    `${history.messages.findLast((message) => message.role === 'assistant')?.id || 'no-message'}:${activity.rows.at(-1)?.id || 'no-runtime'}`
  );
  const updateSync = createDynamicSync();
  let syncSignature = null;
  $effect(() => {
    const signature = chatSyncSignature({ account, chat });
    if (signature !== syncSignature) {
      syncSignature = signature;
      updateSync(buildChatSubscriptions({ account, chat }));
    }
  });
  $effect(() => {
    if (chat.id !== previousChatId) {
      previousChatId = chat.id;
      showMessageTelemetry = false;
    }
  });

  function sent(message) {
    history.append(message);
    window.dispatchEvent(new CustomEvent('runtime-activity-refresh'));
    if (!chat.manual_responses) response.refreshMessages();
    history.scrollToBottom();
  }
  function sendFailed(message) {
    actions.notify(message);
    response.clearWaiting();
  }
</script>

<svelte:head>
  <title>{chat?.title || 'Chat'}</title>
</svelte:head>

<div class="flex min-h-0 flex-1">
  <ChatList
    {chats}
    activeChatId={chat?.id}
    accountId={account.id}
    isOpen={sidebarOpen}
    onClose={() => (sidebarOpen = false)} />
  <main class="flex-1 flex flex-col bg-background min-w-0 min-h-0">
    <!-- Keep header/history scrollable when the keyboard leaves little height. -->
    <div class="flex min-h-0 flex-1 flex-col overflow-y-auto">
      <ChatHeader
        {chat}
        {account}
        {agents}
        allMessages={history.messages}
        {contextTokens}
        {costTokens}
        {costBreakdown}
        {thresholds}
        availableAgents={available_agents}
        addableAgents={addable_agents}
        bind:showAllMessages
        bind:debugMode
        bind:showCosts
        bind:showMessageTelemetry
        onsidebaropen={() => (sidebarOpen = true)}
        onassignagent={() => (actions.ui.assignAgentOpen = true)}
        onaddagent={() => (actions.ui.addAgentOpen = true)}
        onwhiteboardopen={() => (actions.ui.whiteboardOpen = true)}
        onerror={actions.notify}
        onsuccess={(message) => actions.notify(message, 'successMessage')} />
      <TokenWarningBanner level={tokenWarningLevel} {contextTokens} />
      <TelegramBanner {telegramDeepLink} {agents} chatId={chat?.id} />
      {#if debugMode && isSiteAdmin}<ChatDebug />{/if}
      <ChatMessageList
        {agents}
        accountId={account.id}
        bind:messagesContainer={history.container}
        loadingMore={history.loading}
        hasMore={history.hasMore}
        oldestId={history.oldestId}
        {visibleMessages}
        runtimeInteractions={activity.rows}
        allMessages={history.messages}
        {chat}
        {showAllMessages}
        {showMessageTelemetry}
        lastMessageIsHiddenThinking={lastMessageIsHiddenThinking(history.messages)}
        shouldShowSendingPlaceholder={response.placeholder}
        isTimedOut={response.timedOut}
        {shikiTheme}
        showAgentPrompt={response.agentPrompt}
        handleScroll={history.handleScroll}
        loadMoreMessages={history.loadMore}
        startEditingMessage={actions.edit}
        deleteMessage={actions.deleteMessage}
        openImageLightbox={actions.openImage}
        requestVoice={actions.requestVoice} />
    </div>
    <ChatInputArea
      {chat}
      {agents}
      accountId={account.id}
      showUsage={showUsageInChat}
      {agentIsResponding}
      {activeRuntimeAgentIds}
      runtimeInteractions={activity.rows}
      {responseMarker}
      fileUploadConfig={file_upload_config}
      onAgentTrigger={response.refreshMessages}
      onSent={sent}
      onWaiting={response.wait}
      onError={sendFailed}
      onAgentPrompt={response.prompt} />
  </main>
</div>

<ConversationCostDrawer bind:open={showCosts} breakdown={costBreakdown} />
<ChatOverlays
  {chat}
  {account}
  availableAgents={available_agents}
  addableAgents={addable_agents}
  {shikiTheme}
  {agentIsResponding}
  bind:whiteboardOpen={actions.ui.whiteboardOpen}
  bind:editDrawerOpen={actions.ui.editDrawerOpen}
  editingMessageId={actions.ui.editingMessageId}
  editingContent={actions.ui.editingContent}
  errorMessage={actions.ui.errorMessage}
  successMessage={actions.ui.successMessage}
  bind:assignAgentOpen={actions.ui.assignAgentOpen}
  assigningAgent={actions.ui.assigningAgent}
  bind:addAgentOpen={actions.ui.addAgentOpen}
  addAgentProcessing={actions.ui.addAgentProcessing}
  bind:lightboxOpen={actions.ui.lightboxOpen}
  lightboxImage={actions.ui.lightboxImage}
  onEditSaved={actions.editSaved}
  onError={actions.notify}
  onAssignAgent={actions.assignToAgent}
  onAddAgent={actions.addAgentToChat} />
