<script>
  import { page, router } from '@inertiajs/svelte';
  import { Eye } from 'phosphor-svelte';

  let { chatId, accountId } = $props();
  let dismissing = $state(false);
  const explanation =
    'You have a mention or request to respond in this thread. Click to dismiss. Responding to the thread also dismisses this notification.';

  function dismiss(event) {
    event.preventDefault();
    event.stopPropagation();
    const through = $page.props?.reply_attention?.through_messages?.[chatId];
    if (dismissing || !through) return;
    dismissing = true;
    router.post(
      `/accounts/${accountId}/chats/${chatId}/reply_dismissal`,
      { through_message_id: through },
      { preserveScroll: true, preserveState: true, onFinish: () => (dismissing = false) }
    );
  }
</script>

{#if $page.props?.reply_attention?.chats?.[chatId] > 0}
  <button
    type="button"
    class="inline-flex text-red-600 dark:text-red-400 shrink-0 align-middle rounded p-1 hover:bg-red-100 dark:hover:bg-red-950 focus-visible:outline focus-visible:outline-2"
    aria-label={explanation}
    title={explanation}
    disabled={dismissing}
    onclick={dismiss}>
    <Eye size={16} weight="fill" />
  </button>
{/if}
