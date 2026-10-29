<script>
  import { onMount, tick } from 'svelte';
  import { ConversationDraft, DRAFT_LOGOUT } from '$lib/conversation-draft';
  import { ArrowUp, Spinner } from 'phosphor-svelte';
  import FileUploadInput from '$lib/components/chat/FileUploadInput.svelte';
  import { fileDropZone } from '$lib/file-drop-zone';
  import { filesFromPaste } from '$lib/file-upload-rules';
  import MicButton from '$lib/components/chat/MicButton.svelte';
  import { holdForRecording } from '$lib/recording-guard';
  import { withTranscript } from '$lib/voice-note-recovery';
  import { accountChatMessagesPath } from '@/routes';
  import * as logging from '$lib/logging';

  let {
    accountId,
    chatId,
    userId,
    disabled = false,
    manualResponses = false,
    fileUploadConfig = {},
    onsent,
    onwaiting,
    onerror,
    onagentprompt,
  } = $props();

  let selectedFiles = $state([]);
  let uploader = $state(null);
  let submitting = $state(false);
  let pendingAudioSignedId = $state(null);
  let textareaRef = $state(null);
  let draft;
  let draftState = $state({ content: '', status: 'Loading draft…', recoveries: [] });

  // A transcribed voice note's audio is attached only in memory until its message is sent; keep
  // background refreshes (and the reload a deploy turns them into) off until then. Taken before
  // the mic button lets go of its own hold, so there is no gap for a refresh to slip through.
  let releaseAudioHold = null;
  function setPendingAudio(signedId) {
    pendingAudioSignedId = signedId;
    if (signedId) releaseAudioHold ??= holdForRecording({ warn: false });
    else {
      releaseAudioHold?.();
      releaseAudioHold = null;
    }
  }

  onMount(() => {
    draft = new ConversationDraft({
      userId,
      accountId,
      chatId,
      url: `${accountChatMessagesPath(accountId, chatId).replace(/\/messages$/, '')}/draft`,
      onchange: (state) => {
        draftState = state;
        tick().then(autoResize);
      },
    });
    draftState = draft.snapshot();
    draft.refresh();
    const refresh = () => {
      if (document.visibilityState === 'visible') draft.refresh();
    };
    const logout = (event) => {
      if (event.key !== `${DRAFT_LOGOUT}${userId}`) return;
      draft.suppressPersistence = true;
      draft.dispose();
      draftState = {
        ...draftState,
        content: '',
        status: 'Signed out—reload before editing',
        recoveries: [],
        conflict: null,
        locked: true,
      };
    };
    window.addEventListener('storage', logout);
    window.addEventListener('focus', refresh);
    window.addEventListener('online', refresh);
    document.addEventListener('visibilitychange', refresh);
    const poll = setInterval(refresh, 15_000);
    return () => {
      clearInterval(poll);
      window.removeEventListener('storage', logout);
      window.removeEventListener('focus', refresh);
      window.removeEventListener('online', refresh);
      document.removeEventListener('visibilitychange', refresh);
      draft.dispose();
      setPendingAudio(null);
    };
  });

  // Random placeholder (10% chance for the tip)
  const placeholder =
    Math.random() < 0.1 ? 'Did you know? Press shift-enter for a new line...' : 'Type your message...';

  async function sendMessage() {
    if (submitting || disabled || !draft) {
      logging.debug('Already submitting, returning');
      return;
    }

    if (!draftState.content.trim() && selectedFiles.length === 0) {
      logging.debug('Empty message and no files, returning');
      return;
    }

    // Signal waiting state to parent
    onwaiting?.();

    submitting = true;

    try {
      const sent = await draft.beginSend();
      const formData = new FormData();
      formData.append('message[content]', sent.content);
      formData.append('draft_revision', sent.revision);
      selectedFiles.forEach((file) => formData.append('files[]', file));
      if (pendingAudioSignedId) formData.append('audio_signed_id', pendingAudioSignedId);

      const response = await fetch(accountChatMessagesPath(accountId, chatId), {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
          'X-Draft-User': userId,
        },
        credentials: 'same-origin',
        body: formData,
      });

      const data = await response.json().catch(() => ({}));

      if (!response.ok) {
        draft.failed(data.draft);
        const errorPayload = data?.errors || ['Failed to send message'];
        throw new Error(Array.isArray(errorPayload) ? errorPayload.join(', ') : errorPayload);
      }

      // A duplicate acknowledgement does not consume the draft on the server.
      if (!data.draft) throw new Error('Message was not consumed; your draft has been kept');
      draft.sent(sent, data.draft);
      if (draft.disposed) return;
      logging.debug('Message sent successfully');
      submitting = false;
      selectedFiles = [];
      setPendingAudio(null);
      // Reset textarea height
      autoResize();

      // Notify parent of successful send
      onsent?.(data);

      // For group chats, show the agent prompt briefly
      if (manualResponses) {
        onagentprompt?.();
      }
    } catch (error) {
      logging.error('Message send failed:', error);
      draft.failed();
      submitting = false;
      // The draft keeps the text for a retry; keep the voice note's audio (and its hold) too.
      onerror?.(error?.message || 'Failed to send message');
    }
  }

  function handleTranscription(text, audioSignedId, { retry = false } = {}) {
    setPendingAudio(audioSignedId || null);
    // A retried voice note fills the composer and waits for the person to send it: they may
    // have typed meanwhile, or come back after a reload. Their text is kept ahead of it.
    if (retry) {
      draft.edit(withTranscript(draftState.content, text));
      tick().then(autoResize);
      return;
    }
    draft.edit(text);
    sendMessage();
  }

  function handleTranscriptionError(message) {
    onerror?.(message);
  }

  function handleKeydown(event) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      sendMessage();
    }
  }

  // A screenshot or image on the clipboard becomes an attachment; text pastes as text.
  function handlePaste(event) {
    if (submitting || disabled) return;
    const files = filesFromPaste(event.clipboardData);
    if (files.length === 0) return;
    event.preventDefault();
    uploader?.addFiles(files);
  }

  function autoResize() {
    if (!textareaRef) return;
    textareaRef.style.height = 'auto';
    textareaRef.style.height = `${Math.min(textareaRef.scrollHeight, 240)}px`;
  }
</script>

<!-- Message input -->
<div
  class="shrink-0 border-t border-border bg-muted/30 p-3 md:p-4 data-[file-drag]:bg-primary/10 data-[file-drag]:ring-2 data-[file-drag]:ring-inset data-[file-drag]:ring-primary"
  data-testid="message-composer"
  use:fileDropZone={{ onfiles: (files) => uploader?.addFiles(files), disabled: submitting || disabled }}>
  <div class="grid grid-cols-[auto_minmax(0,1fr)_auto_auto] gap-2 md:gap-3 items-start">
    <FileUploadInput
      bind:this={uploader}
      bind:files={selectedFiles}
      disabled={submitting || disabled}
      maxSize={fileUploadConfig.max_size || 50 * 1024 * 1024} />

    <div class="min-w-0 col-start-2 row-start-1">
      <textarea
        bind:this={textareaRef}
        value={draftState.content}
        onpaste={handlePaste}
        onkeydown={handleKeydown}
        oninput={(event) => {
          draft?.edit(event.currentTarget.value);
          autoResize();
        }}
        {placeholder}
        disabled={disabled || draftState.locked}
        class="w-full resize-none border border-input rounded-md px-3 py-2 text-sm bg-background
               focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent
               min-h-[40px] max-h-[min(240px,35dvh)] overflow-y-auto disabled:opacity-50 disabled:cursor-not-allowed"
        style:max-height="min(240px, calc(var(--chat-viewport-height, 100dvh) * 0.35))"
        rows="1"></textarea>
    </div>
    <div class="col-start-3 row-start-1">
      <MicButton
        disabled={submitting || disabled}
        {accountId}
        {chatId}
        {userId}
        onsuccess={handleTranscription}
        onerror={handleTranscriptionError} />
    </div>
    <button
      onclick={sendMessage}
      disabled={(!draftState.content.trim() && selectedFiles.length === 0) ||
        submitting ||
        disabled ||
        !!draftState.conflict}
      aria-label="Send message"
      class="col-start-4 row-start-1 h-10 w-10 p-0 inline-flex items-center justify-center rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:pointer-events-none disabled:opacity-50">
      {#if submitting}
        <Spinner size={16} class="animate-spin" />
      {:else}
        <ArrowUp size={16} />
      {/if}
    </button>
  </div>
  <div
    role="status"
    class={draftState.storageError || draftState.locked || draftState.status.startsWith('Not synced')
      ? 'mt-1 text-xs text-muted-foreground'
      : 'sr-only'}>
    {draftState.status}
    {#if draftState.storageError}
      <span class="text-destructive"> Local recovery unavailable—keep this page open until saved.</span>
    {:else if draftState.localSaved && draftState.status.startsWith('Not synced')}
      <span> Saved on this device.</span>
    {/if}
  </div>
  {#if draftState.conflict}
    <div class="mt-2 text-sm border border-amber-500 rounded p-2" role="alert">
      <p>Another client changed this draft. Your text is still in the editor.</p>
      <pre class="whitespace-pre-wrap max-h-32 overflow-auto my-2">{draftState.conflict.content ||
          '(Empty draft)'}</pre>
      <button class="underline mr-3" onclick={() => draft.resolve(true).catch((e) => onerror?.(e.message))}
        >Keep my text</button>
      <button class="underline" onclick={() => draft.resolve(false)}>Use other draft</button>
    </div>
  {/if}
  {#each draftState.recoveries as copy (copy.key)}
    {#if copy.content !== draftState.content}
      <details class="mt-2 text-sm">
        <summary>Unsynced local draft available</summary>
        <pre class="whitespace-pre-wrap max-h-32 overflow-auto">{copy.content || '(Empty draft)'}</pre>
        <button class="underline" onclick={() => draft.recover(copy)}>Recover this text</button>
      </details>
    {/if}
  {/each}
</div>
