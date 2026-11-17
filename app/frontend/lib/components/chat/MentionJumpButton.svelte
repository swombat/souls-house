<script>
  import { page } from '@inertiajs/svelte';
  import { At } from 'phosphor-svelte';
  import { findMentionElement, nextMentionTarget } from '$lib/mention-jump';

  // The messages in this conversation that flagged you (oldest first, from
  // ReplyExpectation.summary_for). The first tap goes to the newest; each
  // tap after that goes one older, then round to the newest again.
  let { chatId, reveal } = $props();
  const ids = $derived($page.props?.reply_attention?.messages ?? []);
  let cursor = $state(null);
  let busy = $state(false);
  let missed = $state(false);
  let flashTimer;
  let flashed = null;
  const RING = ['ring-2', 'ring-red-500', 'dark:ring-red-400'];

  $effect(() => {
    chatId;
    cursor = null;
    missed = false;
  });

  const label = $derived(
    ids.length === 1
      ? 'Go to the message that mentioned you'
      : `Go to the messages that mentioned you (${ids.length}). Tap again for the one before.`
  );

  function unflash() {
    clearTimeout(flashTimer);
    flashed?.classList.remove(...RING);
    flashed = null;
  }

  // One ring at a time: a new jump takes the ring off the last message
  // before it rings the next, so a quick second tap can't strand one.
  function flash(element) {
    unflash();
    flashed = element.closest('[data-message-card]') ?? element;
    flashed.classList.add(...RING);
    flashTimer = setTimeout(unflash, 2000);
  }

  $effect(() => unflash);

  async function jump() {
    if (busy) return;
    const target = nextMentionTarget(ids, cursor);
    if (!target) return;
    busy = true;
    missed = false;
    try {
      const element = await reveal((root) => findMentionElement(root, target));
      cursor = target;
      if (element) flash(element);
      else missed = true;
    } finally {
      busy = false;
    }
  }
</script>

{#if ids.length > 0}
  <div class="pointer-events-none absolute bottom-3 right-3 z-10 flex flex-col items-end gap-1">
    {#if missed}
      <span class="pointer-events-auto rounded bg-popover px-2 py-1 text-xs text-muted-foreground shadow" role="status">
        Couldn't find that message in the history.
      </span>
    {/if}
    <button
      type="button"
      class="pointer-events-auto inline-flex items-center gap-1 rounded-full border border-red-300 bg-background px-3 py-2 text-sm font-medium text-red-600 shadow-md hover:bg-red-50 focus-visible:outline focus-visible:outline-2 disabled:opacity-60 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950"
      aria-label={label}
      title={label}
      data-testid="mention-jump"
      disabled={busy}
      onclick={jump}>
      <At size={18} weight="bold" />
      {#if ids.length > 1}<span>{ids.length}</span>{/if}
    </button>
  </div>
{/if}
