<script>
  import { page, router } from '@inertiajs/svelte';
  import { Eye } from 'phosphor-svelte';
  import { Popover } from 'bits-ui';

  let { chatId, accountId, messageId = null } = $props();
  const explanationId = $props.id();
  let dismissing = $state(false);
  let showingExplanation = $state(false);
  let button = $state(null);
  let pointerType = '';
  const through = $derived(messageId || $page.props?.reply_attention?.through_messages?.[chatId]);
  const flagged = $derived(
    messageId
      ? $page.props?.reply_attention?.messages?.includes(messageId)
      : $page.props?.reply_attention?.chats?.[chatId] > 0
  );
  const introduction = $derived(
    messageId
      ? 'This message appears to have flagged you for a response.'
      : 'You have a mention or request to respond in this thread.'
  );
  const touchExplanation = $derived(
    `${introduction} Tap again to dismiss ${messageId ? 'this flag' : 'the notification'}. Responding to the thread also dismisses this notification.`
  );
  const explanation = $derived(
    `${introduction} Click to dismiss${messageId ? ' this flag if it is a mistake' : ''}. Responding to the thread also dismisses this notification.`
  );
  const confirmationKey = $derived(JSON.stringify([chatId, through, Boolean(flagged)]));

  $effect(() => {
    // Reset for a different request, not a fresh chat object from live reload.
    confirmationKey;
    showingExplanation = false;
  });

  $effect(() => {
    if (!showingExplanation) return;
    // Capture the completed tap: the popover's debounced touch listener can
    // miss a fast click (notably when tapping the composer).
    const closeOutside = (event) => {
      if (button?.contains(event.target) || document.getElementById(explanationId)?.contains(event.target)) return;
      showingExplanation = false;
    };
    document.addEventListener('click', closeOutside, true);
    return () => document.removeEventListener('click', closeOutside, true);
  });

  function dismiss(event) {
    event.preventDefault();
    event.stopPropagation();
    if (dismissing || !through) return;
    const touch = event.pointerType === 'touch' || pointerType === 'touch';
    pointerType = '';
    if (touch && !showingExplanation) {
      showingExplanation = true;
      return;
    }
    showingExplanation = false;
    dismissing = true;
    router.post(
      `/accounts/${accountId}/chats/${chatId}/reply_dismissal`,
      messageId ? { message_id: messageId } : { through_message_id: through },
      { preserveScroll: true, preserveState: true, onFinish: () => (dismissing = false) }
    );
  }
</script>

{#if flagged}
  <Popover.Root bind:open={showingExplanation}>
    <button
      bind:this={button}
      type="button"
      class="inline-flex items-center gap-1 text-red-600 dark:text-red-400 shrink-0 align-middle rounded p-1 hover:bg-red-100 dark:hover:bg-red-950 focus-visible:outline focus-visible:outline-2 {messageId
        ? 'text-xs mb-2 opacity-75 hover:opacity-100 focus-visible:opacity-100'
        : ''}"
      aria-label={explanation}
      title={explanation}
      aria-expanded={showingExplanation}
      aria-haspopup="dialog"
      aria-controls={showingExplanation ? explanationId : undefined}
      disabled={dismissing}
      onpointerdown={(event) => (pointerType = event.pointerType)}
      onkeydown={() => (pointerType = '')}
      onclick={dismiss}>
      <Eye size={messageId ? 14 : 16} weight="fill" />
      {#if messageId}Flagged you{/if}
    </button>
    <Popover.Portal>
      <Popover.Content
        id={explanationId}
        customAnchor={button}
        side="bottom"
        align="end"
        sideOffset={6}
        trapFocus={false}
        onOpenAutoFocus={(event) => event.preventDefault()}
        onCloseAutoFocus={(event) => event.preventDefault()}
        class="z-50 max-w-[calc(100vw-2rem)] w-64 rounded-md border border-border bg-popover p-3 text-sm text-popover-foreground shadow-md">
        {touchExplanation}
      </Popover.Content>
    </Popover.Portal>
  </Popover.Root>
{/if}
