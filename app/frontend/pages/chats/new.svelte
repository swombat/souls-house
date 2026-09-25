<script>
  import { router } from '@inertiajs/svelte';
  import ChatList from './ChatList.svelte';
  import GroupChatAgentPicker from '$lib/components/chat/GroupChatAgentPicker.svelte';
  import NewChatComposer from '$lib/components/chat/NewChatComposer.svelte';
  import NewChatEmptyState from '$lib/components/chat/NewChatEmptyState.svelte';
  import NewChatHeader from '$lib/components/chat/NewChatHeader.svelte';
  import { accountChatsPath } from '@/routes';

  let {
    chats = [],
    account,
    agents = [],
    show_usage_in_chat: showUsageInChat = false,
    file_upload_config = null,
  } = $props();

  const unpausedAgentIds = () => agents.filter((agent) => agent.paused !== true).map((agent) => agent.id);

  let selectedAgentIds = $state(unpausedAgentIds());
  let sidebarOpen = $state(false);
  let textareaRef = $state(null);
  // Random placeholder (10% chance for the tip)
  const placeholder =
    Math.random() < 0.1
      ? 'Did you know? Press shift-enter for a new line...'
      : 'Type your message to start the chat...';

  let selectedFiles = $state([]);
  let message = $state('');
  let title = $state('');
  let processing = $state(false);
  let pendingAudioSignedId = $state(null);
  let error = $state('');

  function handleTranscription(text, audioSignedId) {
    message = text;
    pendingAudioSignedId = audioSignedId || null;
    startChat();
  }

  function handleKeydown(event) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      startChat();
    }
  }

  function autoResize() {
    if (!textareaRef) return;
    textareaRef.style.height = 'auto';
    textareaRef.style.height = `${Math.min(textareaRef.scrollHeight, 240)}px`;
  }

  function startChat() {
    if (!message.trim() && selectedFiles.length === 0) return;
    if (selectedAgentIds.length === 0) return;
    if (processing) return;

    processing = true;
    error = '';

    // Use FormData to include files
    const formData = new FormData();
    formData.append('message', message);
    if (title.trim()) formData.append('chat[title]', title.trim());
    if (pendingAudioSignedId) formData.append('audio_signed_id', pendingAudioSignedId);

    // Append each file
    selectedFiles.forEach((file) => {
      formData.append('files[]', file);
    });

    selectedAgentIds.forEach((agentId) => {
      formData.append('agent_ids[]', agentId);
    });

    router.post(accountChatsPath(account.id), formData, {
      onSuccess: () => {
        message = '';
        selectedFiles = [];
        pendingAudioSignedId = null;
        processing = false;
        if (textareaRef) textareaRef.style.height = 'auto';
      },
      onError: (errors) => {
        console.error('Chat creation failed:', errors);
        error = 'Could not start the conversation. Please try again.';
        processing = false;
      },
    });
  }
</script>

<svelte:head>
  <title>{title || 'New Chat'}</title>
</svelte:head>

<div class="flex min-h-0 flex-1">
  <!-- Left sidebar: Chat list -->
  <ChatList
    {chats}
    activeChatId={null}
    accountId={account.id}
    isOpen={sidebarOpen}
    onClose={() => (sidebarOpen = false)} />

  <!-- Right side: New chat form -->
  <main class="flex-1 flex flex-col bg-background min-w-0 min-h-0">
    <div class="flex min-h-0 flex-1 flex-col overflow-y-auto">
      <NewChatHeader bind:title onMenuOpen={() => (sidebarOpen = true)} />

      <GroupChatAgentPicker {agents} accountId={account.id} showUsage={showUsageInChat} bind:selectedAgentIds />

      <NewChatEmptyState {chats} accountId={account.id} />
    </div>

    {#if error}
      <p role="alert" class="px-4 py-2 text-destructive">{error}</p>
    {/if}
    <NewChatComposer
      accountId={account.id}
      onTranscription={handleTranscription}
      onError={(message) => (error = message)}
      bind:selectedFiles
      bind:message
      bind:textareaRef
      fileUploadConfig={file_upload_config}
      {processing}
      isGroupChat={true}
      {selectedAgentIds}
      {placeholder}
      onSubmit={startChat}
      onKeydown={handleKeydown}
      onInput={autoResize} />
  </main>
</div>
