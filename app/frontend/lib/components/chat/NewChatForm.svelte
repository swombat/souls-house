<script>
  import { page, router } from '@inertiajs/svelte';
  import { onDestroy, onMount } from 'svelte';
  import ChatList from '@/pages/chats/ChatList.svelte';
  import GroupChatAgentPicker from './GroupChatAgentPicker.svelte';
  import NewChatComposer from './NewChatComposer.svelte';
  import NewChatEmptyState from './NewChatEmptyState.svelte';
  import NewChatHeader from './NewChatHeader.svelte';
  import NewChatRoomPicker from './NewChatRoomPicker.svelte';
  import { accountChatsPath } from '@/routes';
  import { NewConversationDraft } from '$lib/new-conversation-draft';
  import { holdForRecording } from '$lib/recording-guard';
  import { withTranscript } from '$lib/voice-note-recovery';

  let {
    chats = [],
    userId,
    account,
    agents = [],
    show_usage_in_chat: showUsageInChat = false,
    file_upload_config = null,
  } = $props();

  // Keyed by user/account: restore before any binding setter can write.
  const draft = new NewConversationDraft({
    userId,
    accountId: account.id,
    agents,
    onchange: (value) => (draftState = value),
  });
  const restored = draft.snapshot();
  let draftState = $state(restored);
  onDestroy(() => draft.dispose());
  let selectedAgentIds = $state(restored.selectedAgentIds);
  let message = $state(restored.message);
  let title = $state(restored.title);
  let sidebarOpen = $state(false);
  // A new conversation starts in the room being viewed; from All chats, Main.
  let roomId = $state($page.props.current_room === 'all' ? 'main' : $page.props.current_room || 'main');
  let textareaRef = $state(null);
  const placeholder =
    Math.random() < 0.1
      ? 'Did you know? Press shift-enter for a new line...'
      : 'Type your message to start the chat...';

  let selectedFiles = $state([]);
  let processing = $state(false);
  let pendingAudioSignedId = $state(null);
  // The transcribed voice note's audio is attached only in memory until the chat is created, so
  // background refreshes (and the reload a deploy turns them into) wait until then. A failed
  // start keeps both the audio and the hold for the retry.
  let releaseAudioHold = null;
  function setPendingAudio(signedId) {
    pendingAudioSignedId = signedId;
    if (signedId) releaseAudioHold ??= holdForRecording({ warn: false });
    else {
      releaseAudioHold?.();
      releaseAudioHold = null;
    }
  }
  onDestroy(() => setPendingAudio(null));
  let error = $state('');

  function handleTranscription(text, audioSignedId, { retry = false } = {}) {
    // A retried voice note fills the form and waits for the person to start the conversation;
    // anything they typed meanwhile is kept ahead of it.
    if (retry) {
      message = withTranscript(message, text);
      draft.edit({ message });
      setPendingAudio(audioSignedId || null);
      return;
    }
    message = text;
    draft.edit({ message: text });
    setPendingAudio(audioSignedId || null);
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
  onMount(autoResize);

  function startChat() {
    if (!message.trim() && selectedFiles.length === 0) return;
    if (selectedAgentIds.length === 0 || processing) return;

    let submitted;
    try {
      submitted = draft.beginSend();
    } catch (failure) {
      error = failure.message;
      return;
    }
    processing = true;
    error = '';

    const formData = new FormData();
    formData.append('message', message);
    formData.append('draft_submission_id', submitted.submissionId);
    if (title.trim()) formData.append('chat[title]', title.trim());
    if (pendingAudioSignedId) formData.append('audio_signed_id', pendingAudioSignedId);
    selectedFiles.forEach((file) => formData.append('files[]', file));
    selectedAgentIds.forEach((agentId) => formData.append('agent_ids[]', agentId));
    if (($page.props.rooms || []).length) formData.append('room_id', roomId === 'main' ? '' : roomId);

    router.post(accountChatsPath(account.id), formData, {
      headers: userId ? { 'X-Draft-User': userId } : {},
      onSuccess: (page) => {
        if (draft.sent(submitted, page.props?.flash?.draft_submission_id)) {
          message = '';
          title = '';
          selectedFiles = [];
          setPendingAudio(null);
          if (textareaRef) textareaRef.style.height = 'auto';
        }
      },
      onError: () => {
        error = 'Could not start the conversation. Please try again.';
      },
      // Refused redirects, failures and cancellation never clear the draft.
      onFinish: () => (processing = false),
    });
  }
</script>

<svelte:head>
  <title>{title || 'New Chat'}</title>
</svelte:head>

<div class="flex min-h-0 flex-1">
  <ChatList
    {chats}
    activeChatId={null}
    accountId={account.id}
    isOpen={sidebarOpen}
    onClose={() => (sidebarOpen = false)} />

  <main class="flex-1 flex flex-col bg-background min-w-0 min-h-0">
    <div class="flex min-h-0 flex-1 flex-col overflow-y-auto">
      <NewChatHeader
        bind:title={
          () => title,
          (value) => {
            title = value;
            draft.edit({ title: value });
          }
        }
        onMenuOpen={() => (sidebarOpen = true)} />
      <GroupChatAgentPicker
        {agents}
        accountId={account.id}
        showUsage={showUsageInChat}
        bind:selectedAgentIds={
          () => selectedAgentIds,
          (value) => {
            selectedAgentIds = value;
            draft.edit({ selectedAgentIds: value });
          }
        } />
      <NewChatEmptyState {chats} accountId={account.id} />
    </div>

    <NewChatRoomPicker bind:roomId />
    {#if error}
      <p role="alert" class="px-4 py-2 text-destructive">{error}</p>
    {/if}
    <div class="px-4 py-2 text-xs text-muted-foreground" aria-live="polite">
      {#if draftState.storageError}
        <p role="alert">Browser storage is unavailable. This draft may not survive a reload.</p>
      {:else if userId}
        <p>Draft saved only in this browser. Files and audio are not restored.</p>
      {:else}
        <p>Sign in to save a draft in this browser. Files and audio are not restored.</p>
      {/if}
      {#if draftState.submissionId}
        <p role="alert">This conversation may already have been sent; check the sidebar before trying again.</p>
      {/if}
    </div>
    <NewChatComposer
      accountId={account.id}
      {userId}
      onTranscription={handleTranscription}
      onError={(message) => (error = message)}
      bind:selectedFiles
      bind:message={
        () => message,
        (value) => {
          message = value;
          draft.edit({ message: value });
        }
      }
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
