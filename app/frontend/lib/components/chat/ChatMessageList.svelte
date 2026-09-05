<script>
  import * as Card from '$lib/components/shadcn/card/index.js';
  import MessageBubble from '$lib/components/chat/MessageBubble.svelte';
  import AgentRuntimeActivityCard from '$lib/components/chat/AgentRuntimeActivityCard.svelte';
  import { Spinner } from 'phosphor-svelte';
  import { fade } from 'svelte/transition';
  import { formatTime, formatDate } from '$lib/utils';
  import { shouldShowTimestampForMessages, timestampLabelForMessages } from '$lib/chat-message-state';

  let {
    messagesContainer = $bindable(),
    loadingMore = false,
    hasMore = false,
    oldestId = null,
    visibleMessages = [],
    runtimeInteractions = [],
    allMessages = [],
    chat = null,
    showAllMessages = false,
    showMessageTelemetry = false,
    lastMessageIsHiddenThinking = false,
    shouldShowSendingPlaceholder = false,
    isTimedOut = false,
    streamingThinking = {},
    shikiTheme = 'catppuccin-latte',
    showAgentPrompt = false,
    handleScroll = () => {},
    loadMoreMessages = () => {},
    shouldShowTimestamp = () => false,
    timestampLabel = () => '',
    startEditingMessage = () => {},
    deleteMessage = () => {},
    openImageLightbox = () => {},
    requestVoice = () => {},
  } = $props();

  const timelineItems = $derived.by(() => {
    const messageItems = (visibleMessages || []).map((message) => ({
      type: 'message',
      id: `message-${message.id}`,
      created_at: message.created_at,
      message,
    }));

    const runtimeItems = (runtimeInteractions || []).map((interaction) => ({
      type: 'runtime_interaction',
      id: `runtime-${interaction.id}`,
      created_at: interaction.created_at,
      interaction,
    }));

    return [...messageItems, ...runtimeItems].sort((a, b) => {
      const aTime = new Date(a.created_at).getTime();
      const bTime = new Date(b.created_at).getTime();
      return aTime - bTime;
    });
  });

  function shouldShowTimelineTimestamp(index) {
    return shouldShowTimestampForMessages(timelineItems, index);
  }

  function timelineTimestampLabel(index) {
    return timestampLabelForMessages(timelineItems, index, { formatDate, formatTime });
  }
</script>

<!-- Messages container -->
<div bind:this={messagesContainer} onscroll={handleScroll} class="flex-1 overflow-y-auto px-3 md:px-6 py-4 space-y-4">
  {#if loadingMore}
    <div class="flex justify-center py-4">
      <Spinner size={24} class="animate-spin text-muted-foreground" />
    </div>
  {:else if hasMore && oldestId}
    <div class="flex justify-center py-2">
      <button onclick={loadMoreMessages} class="text-sm text-muted-foreground hover:text-foreground">
        Load earlier messages
      </button>
    </div>
  {/if}

  {#if !Array.isArray(timelineItems) || timelineItems.length === 0}
    <div class="flex items-center justify-center h-full">
      <div class="text-center text-muted-foreground">
        <p>Start the conversation by sending a message below.</p>
      </div>
    </div>
  {:else}
    {#each timelineItems as item, index (item.id)}
      {#if shouldShowTimelineTimestamp(index)}
        <div class="flex items-center gap-4 my-6">
          <div class="flex-1 border-t border-border"></div>
          <div class="px-3 py-1 bg-muted rounded-full text-xs font-medium text-muted-foreground">
            {timelineTimestampLabel(index)}
          </div>
          <div class="flex-1 border-t border-border"></div>
        </div>
      {/if}

      {#if item.type === 'message'}
        {@const message = item.message}
        <MessageBubble
          {message}
          isLastVisible={index === timelineItems.length - 1}
          isGroupChat={chat?.manual_responses}
          {showMessageTelemetry}
          streamingThinking={streamingThinking[message.id] || ''}
          {shikiTheme}
          onedit={startEditingMessage}
          ondelete={deleteMessage}
          onimagelightbox={openImageLightbox}
          onvoice={requestVoice} />
      {:else if item.type === 'runtime_interaction'}
        <AgentRuntimeActivityCard interaction={item.interaction} />
      {/if}
    {/each}

    <!-- Thinking bubble when last message is hidden (tool call or empty assistant) - only shown when not showing all messages -->
    {#if !showAllMessages && lastMessageIsHiddenThinking}
      {@const lastMessage = allMessages[allMessages.length - 1]}
      <div class="flex justify-start">
        <div class="max-w-[85%] md:max-w-[70%]">
          <Card.Root>
            <Card.Content class="p-4">
              <div class="flex items-center gap-2 text-muted-foreground">
                <Spinner size={16} class="animate-spin" />
                <span class="text-sm">{lastMessage?.tool_status || 'Thinking...'}</span>
              </div>
            </Card.Content>
          </Card.Root>
        </div>
      </div>
    {/if}

    <!-- Sending message placeholder (show while waiting for assistant response) -->
    {#if shouldShowSendingPlaceholder}
      <div class="flex justify-start">
        <div class="max-w-[85%] md:max-w-[70%]">
          <Card.Root>
            <Card.Content class="p-4">
              {#if isTimedOut}
                <div class="text-red-600 text-sm mb-2">
                  It appears there might have been an error while sending the message.
                </div>
              {:else}
                <div class="flex items-center gap-2 text-muted-foreground">
                  <Spinner size={16} class="animate-spin" />
                  <span class="text-sm">Sending message...</span>
                </div>
              {/if}
            </Card.Content>
          </Card.Root>
        </div>
      </div>
    {/if}

    <!-- Agent prompt for group chats after sending a message -->
    {#if showAgentPrompt && chat?.manual_responses}
      <div class="flex justify-start" transition:fade={{ duration: 200 }}>
        <div class="max-w-[85%] md:max-w-[70%]">
          <Card.Root class="border-dashed border-2 border-muted-foreground/30 bg-muted/20">
            <Card.Content class="p-4">
              <div class="text-muted-foreground text-sm">Please select a resident to respond</div>
            </Card.Content>
          </Card.Root>
        </div>
      </div>
    {/if}
  {/if}
</div>
