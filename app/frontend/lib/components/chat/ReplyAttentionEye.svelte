<script>
  import { page, router } from '@inertiajs/svelte';
  import { Eye } from 'phosphor-svelte';
  import { Popover } from 'bits-ui';

  let { chatId, accountId } = $props();
  const explanationId = $props.id();
  let dismissing = $state(false);
  let showingExplanation = $state(false);
  let button = $state(null);
  let pointerType = '';
  const through = $derived($page.props?.reply_attention?.through_messages?.[chatId]);
  const touchExplanation =
    'You have a mention or request to respond in this thread. Tap again to dismiss the notification. Responding to the thread also dismisses this notification.';
  const explanation =
    'You have a mention or request to respond in this thread. Click to dismiss. Responding to the thread also dismisses this notification.';

  $effect(() => {
    // A newly arriving request needs its own first tap.
    through;
    chatId;
    showingExplanation = false;
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
      { through_message_id: through },
      { preserveScroll: true, preserveState: true, onFinish: () => (dismissing = false) }
    );
  }
</script>

{#if $page.props?.reply_attention?.chats?.[chatId] > 0}
  <Popover.Root bind:open={showingExplanation}>
    <button
      bind:this={button}
      type="button"
      class="inline-flex text-red-600 dark:text-red-400 shrink-0 align-middle rounded p-1 hover:bg-red-100 dark:hover:bg-red-950 focus-visible:outline focus-visible:outline-2"
      aria-label={explanation}
      title={explanation}
      aria-expanded={showingExplanation}
      aria-haspopup="dialog"
      aria-controls={showingExplanation ? explanationId : undefined}
      disabled={dismissing}
      onpointerdown={(event) => (pointerType = event.pointerType)}
      onkeydown={() => (pointerType = '')}
      onclick={dismiss}>
      <Eye size={16} weight="fill" />
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
