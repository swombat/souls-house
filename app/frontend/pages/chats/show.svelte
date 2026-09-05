<script>
  import { page } from '@inertiajs/svelte';
  import { useForm } from '@inertiajs/svelte';
  import { createDynamicSync, streamingSync } from '$lib/use-sync';
  import { router } from '@inertiajs/svelte';
  import { onMount, onDestroy } from 'svelte';
  import ChatList from './ChatList.svelte';
  import ChatHeader from '$lib/components/chat/ChatHeader.svelte';
  import TokenWarningBanner from '$lib/components/chat/TokenWarningBanner.svelte';
  import ChatMessageList from '$lib/components/chat/ChatMessageList.svelte';
  import ChatInputArea from '$lib/components/chat/ChatInputArea.svelte';
  import TelegramBanner from '$lib/components/chat/TelegramBanner.svelte';
  import DebugPanel from '$lib/components/chat/DebugPanel.svelte';
  import ChatOverlays from '$lib/components/chat/ChatOverlays.svelte';
  import ConversationCostDrawer from '$lib/components/chat/ConversationCostDrawer.svelte';
  import {
    accountChatMessagesPath,
    accountChatAgentAssignmentPath,
    messagePath,
    accountChatParticipantPath,
  } from '@/routes';
  import * as logging from '$lib/logging';
  import { formatTime, formatDate } from '$lib/utils';
  import { tokenWarningLevel as getTokenWarningLevel } from '$lib/chat-utils';
  import {
    isChatResponseTimedOut,
    lastMessageIsHiddenThinking as messageStateLastMessageIsHiddenThinking,
    lastMessageIsUserWithoutResponse as messageStateLastMessageIsUserWithoutResponse,
    lastUserMessageTime as messageStateLastUserMessageTime,
    shouldShowSendingPlaceholder as messageStateShouldShowSendingPlaceholder,
    shouldShowTimestampForMessages,
    timestampLabelForMessages,
    visibleChatMessages,
  } from '$lib/chat-message-state';
  import {
    combinePaginatedMessages,
    prependOlderMessages,
    preserveDisplacedRecentMessages,
    shouldLoadMoreMessages,
  } from '$lib/chat-pagination-state';
  import {
    appendMessageIfMissing,
    patchMessageInCollections,
    removeMessageFromCollections,
  } from '$lib/chat-message-collections';
  import { applyStreamingEnd, applyStreamingUpdate } from '$lib/chat-streaming-state';
  import { buildChatSubscriptions, chatSyncSignature } from '$lib/chat-sync-subscriptions';
  import { mode } from 'mode-watcher';

  const shikiTheme = $derived(mode.current === 'dark' ? 'catppuccin-mocha' : 'catppuccin-latte');

  // Browser check for event listeners
  const browser = typeof window !== 'undefined';

  // CSRF token helper
  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || '';
  }

  // Voice route helper (until js:routes:generate is run with the new route)
  function messageVoicePath(messageId) {
    return `/messages/${messageId}/voice`;
  }

  let {
    chat,
    chats = [],
    messages: recentMessages = [],
    runtime_interactions: runtimeInteractions = [],
    cost_breakdown: costBreakdown = {},
    has_more_messages: serverHasMore = false,
    oldest_message_id: serverOldestId = null,
    account,
    models = [],
    agents = [],
    available_agents = [],
    addable_agents = [],
    show_usage_in_chat: showUsageInChat = false,
    file_upload_config = {},
    telegram_deep_link: telegramDeepLink = null,
  } = $props();

  // Older messages loaded via pagination (not managed by Inertia)
  let olderMessages = $state([]);
  let hasMore = $state(serverHasMore);
  let oldestId = $state(serverOldestId);
  let loadingMore = $state(false);
  let previousRecentMessages = [];
  let previousRecentChatId = null;

  const allMessages = $derived(combinePaginatedMessages(olderMessages, recentMessages));

  // Token thresholds from server
  const thresholds = $derived($page.props.token_thresholds || { amber: 100_000, red: 150_000, critical: 200_000 });

  // Server-provided context (active replayed prompt) and cost (lifetime billed) tokens
  const contextTokens = $derived(chat?.context_tokens || 0);
  const costTokens = $derived(chat?.cost_tokens || { input: 0, output: 0 });

  // Token warning level — driven by active context size, not lifetime cost
  const tokenWarningLevel = $derived(getTokenWarningLevel(contextTokens, thresholds));

  // Explicit chat reset tracking
  let previousChatId = null;

  $effect(() => {
    if (chat?.id !== previousChatId) {
      previousChatId = chat?.id;
      olderMessages = [];
      hasMore = serverHasMore;
      oldestId = serverOldestId;
    }
  });

  // A sync reload always returns the newest 30 messages. Preserve records that
  // were in the previous window but were pushed out by newly-arrived messages,
  // otherwise a long open conversation develops gaps at the pagination seam.
  $effect(() => {
    const currentChatId = chat?.id ?? null;
    const currentRecentMessages = recentMessages || [];

    if (currentChatId !== previousRecentChatId) {
      previousRecentChatId = currentChatId;
      previousRecentMessages = currentRecentMessages;
    } else {
      olderMessages = preserveDisplacedRecentMessages({
        olderMessages,
        previousRecentMessages,
        recentMessages: currentRecentMessages,
      });
      previousRecentMessages = currentRecentMessages;
    }
  });

  // Update pagination state when server props change, but only if we haven't paginated yet
  $effect(() => {
    if (olderMessages.length === 0) {
      hasMore = serverHasMore;
      oldestId = serverOldestId;
    }
  });

  let messagesContainer = $state();
  let waitingForResponse = $state(false);
  let messageSentAt = $state(null);
  let currentTime = $state(Date.now());
  let timeoutCheckInterval;
  let showAllMessages = $state(false);
  let debugMode = $state(false);
  let showCosts = $state(false);
  let showMessageTelemetry = $state(false);
  let messageTelemetryChatId = chat?.id;
  let debugLogs = $state([]);
  // Brief "select an agent" prompt for group chats after sending a message
  let showAgentPrompt = $state(false);
  // Mobile sidebar state
  let sidebarOpen = $state(false);

  // Whiteboard state
  let whiteboardOpen = $state(false);

  // Assign agent dialog state
  let assignAgentOpen = $state(false);
  let assigningAgent = $state(false);

  // Add agent dialog state
  let addAgentOpen = $state(false);
  let addAgentProcessing = $state(false);

  // Thinking streaming state
  let streamingThinking = $state({});

  // Streaming safety-net refresh timer
  let streamingRefreshTimer = null;

  $effect(() => {
    if (chat?.id !== messageTelemetryChatId) {
      messageTelemetryChatId = chat?.id;
      showMessageTelemetry = false;
    }
  });

  function scheduleStreamingRefresh(delayMs = 5000) {
    if (streamingRefreshTimer) clearTimeout(streamingRefreshTimer);
    streamingRefreshTimer = setTimeout(() => {
      streamingRefreshTimer = null;
      router.reload({
        only: ['messages'],
        preserveScroll: true,
        onSuccess: () => {
          // If any message is still streaming, schedule another refresh in 10s
          if (recentMessages?.some((m) => m.streaming)) {
            scheduleStreamingRefresh(10000);
          }
        },
      });
    }, delayMs);
  }

  // Error handling state
  let errorMessage = $state(null);
  let successMessage = $state(null);

  // Image lightbox state
  let lightboxOpen = $state(false);
  let lightboxImage = $state(null);

  function openImageLightbox(file) {
    lightboxImage = file;
    lightboxOpen = true;
  }

  // Edit message state
  let editDrawerOpen = $state(false);
  let editingMessageId = $state(null);
  let editingContent = $state('');

  // Check if current user is a site admin
  const isSiteAdmin = $derived($page.props.user?.site_admin ?? false);

  // Check if current user is an account admin
  const isAccountAdmin = $derived($page.props.is_account_admin ?? false);

  // Check if user is near the bottom of the messages container (within 50px)
  function isNearBottom() {
    if (!messagesContainer) return true;
    const { scrollTop, scrollHeight, clientHeight } = messagesContainer;
    return scrollTop + clientHeight >= scrollHeight - 100;
  }

  // Scroll to bottom smoothly if user is near the bottom
  function scrollToBottomIfNeeded() {
    if (messagesContainer && isNearBottom()) {
      messagesContainer.scrollTo({
        top: messagesContainer.scrollHeight,
        behavior: 'smooth',
      });
    }
  }

  // Scroll to bottom unconditionally (e.g. after user sends a message)
  function scrollToBottom() {
    if (messagesContainer) {
      messagesContainer.scrollTo({
        top: messagesContainer.scrollHeight,
        behavior: 'smooth',
      });
    }
  }

  // Handle scroll for loading more messages
  function handleScroll() {
    if (!messagesContainer) return;
    if (
      shouldLoadMoreMessages({
        scrollTop: messagesContainer.scrollTop,
        hasMore,
        loadingMore,
        oldestId,
      })
    ) {
      loadMoreMessages();
    }
  }

  // Load more messages from the server
  async function loadMoreMessages() {
    if (loadingMore || !hasMore || !oldestId) return;

    loadingMore = true;
    const container = messagesContainer;
    const previousHeight = container.scrollHeight;

    try {
      const response = await fetch(accountChatMessagesPath(account.id, chat.id, { before_id: oldestId }), {
        headers: {
          Accept: 'application/json',
          'X-CSRF-Token': csrfToken(),
        },
      });

      if (response.ok) {
        const data = await response.json();
        const pagination = prependOlderMessages({
          olderMessages,
          newMessages: data.messages,
          hasMore: data.has_more,
          oldestId: data.oldest_id,
        });
        olderMessages = pagination.olderMessages;
        hasMore = pagination.hasMore;
        oldestId = pagination.oldestId;

        // Simple scroll preservation with requestAnimationFrame
        requestAnimationFrame(() => {
          container.scrollTop += container.scrollHeight - previousHeight;
        });
      }
    } catch (error) {
      logging.error('Failed to load more messages:', error);
    } finally {
      loadingMore = false;
    }
  }

  // Helper to update a message in both recentMessages and olderMessages
  function updateMessage(messageId, patch) {
    const result = patchMessageInCollections({ recentMessages, olderMessages, messageId, patch });
    recentMessages = result.recentMessages;
    olderMessages = result.olderMessages;
  }

  // Request voice synthesis for a message
  async function requestVoice(messageId) {
    updateMessage(messageId, { _voice_loading: true });

    try {
      const response = await fetch(messageVoicePath(messageId), {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken(), Accept: 'application/json' },
      });

      if (response.status === 200) {
        const { voice_audio_url } = await response.json();
        updateMessage(messageId, { voice_audio_url, _voice_loading: false });
      } else if (response.status !== 202) {
        updateMessage(messageId, { _voice_loading: false });
      }
      // 202: loading state clears when Broadcastable refresh replaces the message
    } catch {
      updateMessage(messageId, { _voice_loading: false });
    }
  }

  // Filter out tool messages and empty assistant messages unless admin has enabled "show all messages"
  const visibleMessages = $derived(visibleChatMessages(allMessages, showAllMessages));

  // Count unique human participants in group chats
  const uniqueHumanCount = $derived.by(() => {
    if (!allMessages || allMessages.length === 0) return 0;
    const humanNames = new Set(allMessages.filter((m) => m.role === 'user' && m.author_name).map((m) => m.author_name));
    return humanNames.size;
  });

  // Check if the last actual message is hidden (tool call or empty assistant) - model is still thinking
  const lastMessageIsHiddenThinking = $derived.by(() => {
    return messageStateLastMessageIsHiddenThinking(allMessages);
  });

  // Check if the last message is a user message without a response
  const lastMessageIsUserWithoutResponse = $derived.by(() => {
    return messageStateLastMessageIsUserWithoutResponse(allMessages);
  });

  // Check if any agent is currently responding (streaming)
  const agentIsResponding = $derived(allMessages?.some((m) => m.streaming) ?? false);
  const activeRuntimeAgentIds = $derived(
    (runtimeInteractions || []).filter((interaction) => interaction.active).map((interaction) => interaction.agent_id)
  );
  const latestAssistantMessageId = $derived.by(() => {
    const assistantMessage = [...(allMessages || [])].reverse().find((message) => message.role === 'assistant');
    return assistantMessage?.id ?? null;
  });
  const latestRuntimeInteractionId = $derived(runtimeInteractions?.[runtimeInteractions.length - 1]?.id ?? null);
  const responseMarker = $derived(
    `${latestAssistantMessageId || 'no-message'}:${latestRuntimeInteractionId || 'no-runtime'}`
  );

  // Auto-detect waiting state based on messages
  // Don't show for manual_responses chats (group chats) since they don't auto-respond
  const shouldShowSendingPlaceholder = $derived(
    messageStateShouldShowSendingPlaceholder({ chat, messages: allMessages, waitingForResponse })
  );

  // Get the timestamp of when the last user message was sent
  const lastUserMessageTime = $derived.by(() => {
    return messageStateLastUserMessageTime(allMessages);
  });

  // Check if we've been waiting too long (over 1 minute)
  const isTimedOut = $derived.by(() => {
    return isChatResponseTimedOut({ chat, messages: allMessages, waitingForResponse, messageSentAt, currentTime });
  });

  // Create dynamic sync for real-time updates
  const updateSync = createDynamicSync();
  let syncSignature = null;

  // Set up timer to check for timeouts
  onMount(() => {
    if (messagesContainer) {
      messagesContainer.scrollTop = messagesContainer.scrollHeight;
    }

    // Set up interval to check for timeouts
    timeoutCheckInterval = setInterval(() => {
      currentTime = Date.now();
    }, 5000); // Check every 5 seconds
  });

  // Handle debug log events from the sync channel
  function handleDebugLog(event) {
    const data = event.detail;
    debugLogs = [...debugLogs, { level: data.level, message: data.message, time: data.time }].slice(-100);
  }

  onDestroy(() => {
    if (timeoutCheckInterval) {
      clearInterval(timeoutCheckInterval);
    }
    if (streamingRefreshTimer) {
      clearTimeout(streamingRefreshTimer);
    }
  });

  // Listen for debug log events when debug mode is enabled
  $effect(() => {
    if (debugMode && isSiteAdmin && browser) {
      window.addEventListener('debug-log', handleDebugLog);
      logging.debug('Debug log listener enabled');
      return () => {
        window.removeEventListener('debug-log', handleDebugLog);
        logging.debug('Debug log listener disabled');
      };
    }
  });

  // Set up real-time subscriptions - SIMPLIFIED (no message count comparison)
  $effect(() => {
    const subs = buildChatSubscriptions({ account, chat });
    const nextSignature = chatSyncSignature({ account, chat, recentMessages });

    if (nextSignature !== syncSignature) {
      syncSignature = nextSignature;
      updateSync(subs);
    }
    // ActionCable broadcasts handle new messages automatically
  });

  // Auto-scroll to bottom when messages change (only if user is near bottom)
  $effect(() => {
    recentMessages; // Subscribe to messages changes

    // Clear waiting state if an assistant message appeared
    if (waitingForResponse && recentMessages.length > 0) {
      const lastMessage = recentMessages[recentMessages.length - 1];
      if (lastMessage.role === 'assistant') {
        waitingForResponse = false;
        messageSentAt = null;
      }
    }

    if (messagesContainer) {
      setTimeout(() => {
        scrollToBottomIfNeeded();
      }, 100);
    }
  });

  streamingSync(
    (data) => {
      if (data.id) {
        const index = recentMessages.findIndex((m) => m.id === data.id);
        if (index !== -1) {
          const result = applyStreamingUpdate({ messages: recentMessages, streamingThinking }, data);
          if (result.handled) {
            streamingThinking = result.streamingThinking;
            recentMessages = result.messages;

            // Scroll to bottom if user is near the bottom during streaming
            setTimeout(() => {
              scrollToBottomIfNeeded();
            }, 0);
          }
        } else {
          logging.debug('No message found in streaming update:', data.id);
          logging.debug('Messages:', recentMessages);
        }
      } else if (data.action === 'error' || data.action === 'agent_skipped') {
        // Handle transient errors
        errorMessage = data.message;
        setTimeout(() => (errorMessage = null), 5000);
      } else {
        logging.warn('No id found in streaming update:', data);
      }
    },
    (data) => {
      if (data.id) {
        const result = applyStreamingEnd({ messages: recentMessages, streamingThinking }, data);
        streamingThinking = result.streamingThinking;
        recentMessages = result.messages;

        if (result.handled) {
          logging.debug('Updating message via streaming end:', data.id);
        }
      } else {
        logging.warn('No id found in streaming end:', data);
      }
    }
  );

  function assignToAgent(agentId) {
    if (!chat || !agentId) return;
    assigningAgent = true;
    router.post(
      accountChatAgentAssignmentPath(account.id, chat.id),
      { agent_id: agentId },
      {
        onFinish: () => {
          assigningAgent = false;
          assignAgentOpen = false;
        },
      }
    );
  }

  function addAgentToChat(agentId) {
    if (!chat || !agentId) return;
    addAgentProcessing = true;
    router.post(
      accountChatParticipantPath(account.id, chat.id),
      { agent_id: agentId },
      {
        onFinish: () => {
          addAgentProcessing = false;
          addAgentOpen = false;
        },
      }
    );
  }

  function startEditingMessage(message) {
    editingMessageId = message.id;
    editingContent = message.content;
    editDrawerOpen = true;
  }

  async function deleteMessage(messageId) {
    if (!confirm('Delete this message?')) return;

    try {
      const response = await fetch(messagePath(messageId), {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': csrfToken(),
        },
      });

      if (response.ok) {
        const result = removeMessageFromCollections({ recentMessages, olderMessages, messageId });
        recentMessages = result.recentMessages;
        olderMessages = result.olderMessages;
        // Reload to get proper server state
        router.reload({ only: ['messages'], preserveScroll: true });
      } else {
        errorMessage = 'Failed to delete message';
        setTimeout(() => (errorMessage = null), 3000);
      }
    } catch (error) {
      errorMessage = 'Failed to delete message';
      setTimeout(() => (errorMessage = null), 3000);
    }
  }

  function shouldShowTimestamp(index) {
    return shouldShowTimestampForMessages(visibleMessages, index);
  }

  function timestampLabel(index) {
    return timestampLabelForMessages(visibleMessages, index, { formatDate, formatTime });
  }
</script>

<svelte:head>
  <title>{chat?.title || 'Chat'}</title>
</svelte:head>

<div class="flex h-[calc(100dvh-4rem)]">
  <!-- Left sidebar: Chat list -->
  <ChatList
    {chats}
    activeChatId={chat?.id}
    accountId={account.id}
    isOpen={sidebarOpen}
    onClose={() => (sidebarOpen = false)} />

  <!-- Right side: Chat messages -->
  <main class="flex-1 flex flex-col bg-background min-w-0">
    <!-- Chat header -->
    <ChatHeader
      {chat}
      {account}
      {agents}
      {allMessages}
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
      onassignagent={() => (assignAgentOpen = true)}
      onaddagent={() => (addAgentOpen = true)}
      onwhiteboardopen={() => (whiteboardOpen = true)}
      onerror={(msg) => {
        errorMessage = msg;
        setTimeout(() => (errorMessage = null), 3000);
      }}
      onsuccess={(msg) => {
        successMessage = msg;
        setTimeout(() => (successMessage = null), 3000);
      }} />

    <TokenWarningBanner level={tokenWarningLevel} {contextTokens} />

    <!-- Telegram notification banner -->
    <TelegramBanner {telegramDeepLink} {agents} chatId={chat?.id} />

    <!-- Debug panel for site admins -->
    {#if debugMode && isSiteAdmin}
      <DebugPanel logs={debugLogs} onclear={() => (debugLogs = [])} />
    {/if}

    <ChatMessageList
      bind:messagesContainer
      {loadingMore}
      {hasMore}
      {oldestId}
      {visibleMessages}
      {runtimeInteractions}
      {allMessages}
      {chat}
      {showAllMessages}
      {showMessageTelemetry}
      {lastMessageIsHiddenThinking}
      {shouldShowSendingPlaceholder}
      {isTimedOut}
      {streamingThinking}
      {shikiTheme}
      {showAgentPrompt}
      {handleScroll}
      {loadMoreMessages}
      {shouldShowTimestamp}
      {timestampLabel}
      {startEditingMessage}
      {deleteMessage}
      {openImageLightbox}
      {requestVoice} />

    <ChatInputArea
      {chat}
      {agents}
      accountId={account.id}
      showUsage={showUsageInChat}
      {agentIsResponding}
      {activeRuntimeAgentIds}
      {responseMarker}
      fileUploadConfig={file_upload_config}
      onAgentTrigger={scheduleStreamingRefresh}
      onSent={(data) => {
        recentMessages = appendMessageIfMissing(recentMessages, data);
        if (!chat?.manual_responses) scheduleStreamingRefresh();
        setTimeout(() => scrollToBottom(), 50);
      }}
      onWaiting={() => {
        if (!chat?.manual_responses) {
          waitingForResponse = true;
          messageSentAt = Date.now();
        }
      }}
      onError={(msg) => {
        errorMessage = msg;
        setTimeout(() => (errorMessage = null), 5000);
        waitingForResponse = false;
        messageSentAt = null;
      }}
      onAgentPrompt={() => {
        showAgentPrompt = true;
        setTimeout(() => {
          showAgentPrompt = false;
        }, 3000);
      }} />
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
  bind:whiteboardOpen
  bind:editDrawerOpen
  {editingMessageId}
  {editingContent}
  {errorMessage}
  {successMessage}
  bind:assignAgentOpen
  {assigningAgent}
  bind:addAgentOpen
  {addAgentProcessing}
  bind:lightboxOpen
  {lightboxImage}
  onEditSaved={(messageId, trimmedContent) => {
    updateMessage(messageId, { content: trimmedContent, editable: false });
    editDrawerOpen = false;
    editingMessageId = null;
    editingContent = '';
  }}
  onError={(msg) => {
    errorMessage = msg;
    setTimeout(() => (errorMessage = null), 3000);
  }}
  onAssignAgent={assignToAgent}
  onAddAgent={addAgentToChat} />
