<script>
  import { useForm } from '@inertiajs/svelte';
  import { ArrowUp, Spinner } from 'phosphor-svelte';
  import FileUploadInput from '$lib/components/chat/FileUploadInput.svelte';
  import MicButton from '$lib/components/chat/MicButton.svelte';
  import { accountChatMessagesPath } from '@/routes';
  import * as logging from '$lib/logging';

  let {
    accountId,
    chatId,
    disabled = false,
    manualResponses = false,
    fileUploadConfig = {},
    onsent,
    onwaiting,
    onerror,
    onagentprompt,
  } = $props();

  let selectedFiles = $state([]);
  let submitting = $state(false);
  let pendingAudioSignedId = $state(null);
  let textareaRef = $state(null);

  // Random placeholder (10% chance for the tip)
  const placeholder =
    Math.random() < 0.1 ? 'Did you know? Press shift-enter for a new line...' : 'Type your message...';

  // Initialize the form with the structure the controller expects
  let messageForm = useForm({
    message: {
      content: '',
    },
  });

  async function sendMessage() {
    logging.debug('messageForm:', $messageForm);

    if (submitting) {
      logging.debug('Already submitting, returning');
      return;
    }

    if (!$messageForm.message.content.trim() && selectedFiles.length === 0) {
      logging.debug('Empty message and no files, returning');
      return;
    }

    const formData = new FormData();
    formData.append('message[content]', $messageForm.message.content);
    selectedFiles.forEach((file) => formData.append('files[]', file));

    if (pendingAudioSignedId) {
      formData.append('audio_signed_id', pendingAudioSignedId);
    }

    // Signal waiting state to parent
    onwaiting?.();

    submitting = true;

    try {
      const response = await fetch(accountChatMessagesPath(accountId, chatId), {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        credentials: 'same-origin',
        body: formData,
      });

      const data = await response.json().catch(() => ({}));

      if (!response.ok) {
        const errorPayload = data?.errors || ['Failed to send message'];
        throw new Error(Array.isArray(errorPayload) ? errorPayload.join(', ') : errorPayload);
      }

      logging.debug('Message sent successfully');
      submitting = false;
      $messageForm.message.content = '';
      selectedFiles = [];
      pendingAudioSignedId = null;
      // Reset textarea height
      if (textareaRef) textareaRef.style.height = 'auto';

      // Notify parent of successful send
      onsent?.(data);

      // For group chats, show the agent prompt briefly
      if (manualResponses) {
        onagentprompt?.();
      }
    } catch (error) {
      logging.error('Message send failed:', error);
      submitting = false;
      pendingAudioSignedId = null;
      onerror?.(error?.message || 'Failed to send message');
    }
  }

  function handleTranscription(text, audioSignedId) {
    pendingAudioSignedId = audioSignedId || null;
    $messageForm.message.content = text;
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

  function autoResize() {
    if (!textareaRef) return;
    textareaRef.style.height = 'auto';
    textareaRef.style.height = `${Math.min(textareaRef.scrollHeight, 240)}px`;
  }
</script>

<!-- Message input -->
<div class="shrink-0 border-t border-border bg-muted/30 p-3 md:p-4" data-testid="message-composer">
  <div class="grid grid-cols-[auto_minmax(0,1fr)_auto_auto] gap-2 md:gap-3 items-start">
    <FileUploadInput
      bind:files={selectedFiles}
      disabled={submitting || disabled}
      allowedTypes={fileUploadConfig.acceptable_types || []}
      allowedExtensions={fileUploadConfig.acceptable_extensions || []}
      maxSize={fileUploadConfig.max_size || 50 * 1024 * 1024} />

    <div class="min-w-0 col-start-2 row-start-1">
      <textarea
        bind:this={textareaRef}
        bind:value={$messageForm.message.content}
        onkeydown={handleKeydown}
        oninput={autoResize}
        {placeholder}
        disabled={submitting || disabled}
        class="w-full resize-none border border-input rounded-md px-3 py-2 text-sm bg-background
               focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent
               min-h-[40px] max-h-[240px] overflow-y-auto disabled:opacity-50 disabled:cursor-not-allowed"
        rows="1"></textarea>
    </div>
    <div class="col-start-3 row-start-1">
      <MicButton
        disabled={submitting || disabled}
        {accountId}
        {chatId}
        onsuccess={handleTranscription}
        onerror={handleTranscriptionError} />
    </div>
    <button
      onclick={sendMessage}
      disabled={(!$messageForm.message.content.trim() && selectedFiles.length === 0) || submitting || disabled}
      aria-label="Send message"
      class="col-start-4 row-start-1 h-10 w-10 p-0 inline-flex items-center justify-center rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:pointer-events-none disabled:opacity-50">
      {#if submitting}
        <Spinner size={16} class="animate-spin" />
      {:else}
        <ArrowUp size={16} />
      {/if}
    </button>
  </div>
</div>
