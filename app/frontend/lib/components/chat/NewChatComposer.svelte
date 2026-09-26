<script>
  import FileUploadInput from '$lib/components/chat/FileUploadInput.svelte';
  import MicButton from '$lib/components/chat/MicButton.svelte';
  import { ArrowUp } from 'phosphor-svelte';

  let {
    selectedFiles = $bindable([]),
    accountId,
    onTranscription,
    onError,
    message = $bindable(''),
    textareaRef = $bindable(null),
    fileUploadConfig = {},
    processing = false,
    isGroupChat = false,
    selectedAgentIds = [],
    placeholder = 'Type your message to start the chat...',
    onSubmit,
    onKeydown,
    onInput,
  } = $props();
</script>

<div class="shrink-0 border-t border-border bg-muted/30 p-3 md:p-4" data-testid="message-composer">
  <div class="grid grid-cols-[auto_minmax(0,1fr)_auto_auto] gap-2 md:gap-3 items-start">
    <FileUploadInput
      bind:files={selectedFiles}
      disabled={processing}
      maxSize={fileUploadConfig?.max_size || 52428800} />

    <div class="min-w-0 col-start-2 row-start-1">
      <textarea
        bind:this={textareaRef}
        bind:value={message}
        onkeydown={onKeydown}
        oninput={onInput}
        {placeholder}
        disabled={processing}
        class="w-full resize-none border border-input rounded-md px-3 py-2 text-sm bg-background
               focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent
               min-h-[40px] max-h-[min(240px,35dvh)] overflow-y-auto"
        style:max-height="min(240px, calc(var(--chat-viewport-height, 100dvh) * 0.35))"
        rows="1"></textarea>
    </div>
    <div class="col-start-3 row-start-1">
      <MicButton
        {accountId}
        disabled={processing || (isGroupChat && selectedAgentIds.length === 0)}
        onsuccess={onTranscription}
        onerror={onError} />
    </div>
    <button
      onclick={onSubmit}
      disabled={(!message.trim() && selectedFiles.length === 0) ||
        processing ||
        (isGroupChat && selectedAgentIds.length === 0)}
      aria-label="Start conversation"
      class="col-start-4 row-start-1 h-10 w-10 p-0 inline-flex items-center justify-center rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:pointer-events-none disabled:opacity-50">
      <ArrowUp size={16} />
    </button>
  </div>
</div>
