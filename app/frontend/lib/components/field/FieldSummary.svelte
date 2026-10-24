<script>
  import { router } from '@inertiajs/svelte';
  import { ArrowClockwise } from 'phosphor-svelte';

  // A Field item's one-sentence summary, with a way to have it written again
  // (after a transcript has been corrected, say). With a mouse the refresh
  // button shows on hover; on touch, tapping the summary shows it. The old
  // summary stays until the new one arrives, by the page's own refresh.
  let {
    text,
    pending = false,
    failed = false,
    freshness = null,
    url = null,
    testid = 'field-summary',
    children,
  } = $props();

  let finePointer = $state(true);
  $effect(() => {
    const query = window.matchMedia('(hover: hover) and (pointer: fine)');
    finePointer = query.matches;
    const change = (event) => (finePointer = event.matches);
    query.addEventListener('change', change);
    return () => query.removeEventListener('change', change);
  });

  let revealed = $state(false);
  let requesting = $state(false);
  let error = $state('');
  const working = $derived(pending || requesting);

  function refresh(event) {
    event.stopPropagation();
    if (!url || working) return;
    requesting = true;
    error = '';
    let accepted = false;
    router.post(
      url,
      {},
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => (accepted = true),
        onError: (errors) => (error = errors?.summary || "The summary couldn't be redone."),
        onFinish: () => {
          requesting = false;
          if (!accepted && !error) error = "That didn't go through. Try again.";
        },
      }
    );
  }

  function tap() {
    if (!finePointer && url) revealed = !revealed;
  }
</script>

<div class="group">
  <div class="flex items-start gap-2">
    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
    <p class="text-sm min-w-0 {working ? 'text-muted-foreground' : ''}" data-testid={testid} onclick={tap}>
      {text}
      {@render children?.()}
    </p>
    {#if url && (finePointer || revealed || working || failed || freshness === 'stale' || freshness === 'unknown')}
      <button
        type="button"
        class="shrink-0 rounded p-1 text-muted-foreground hover:text-foreground hover:bg-muted disabled:cursor-default {finePointer &&
        !working &&
        !failed &&
        freshness !== 'stale' &&
        freshness !== 'unknown'
          ? 'opacity-0 transition-opacity group-hover:opacity-100 focus:opacity-100'
          : ''}"
        aria-label="Write the summary again"
        title="Write the summary again"
        disabled={working}
        data-testid="summary-refresh"
        onclick={refresh}>
        <ArrowClockwise class="size-4 {working ? 'animate-spin' : ''}" />
      </button>
    {/if}
  </div>
  {#if working}
    <p class="text-xs text-muted-foreground mt-1" data-testid="summary-pending">Writing a new summary…</p>
  {:else if error}
    <p class="text-xs text-destructive mt-1" data-testid="summary-error">{error}</p>
  {:else if failed}
    <p class="text-xs text-destructive mt-1" data-testid="summary-failed">
      A new summary couldn't be written; this is the old one. Try again?
    </p>
  {:else if freshness === 'stale'}
    <p class="text-xs text-muted-foreground mt-1" data-testid="summary-stale">Summary is out of date.</p>
  {:else if freshness === 'unknown'}
    <p class="text-xs text-muted-foreground mt-1" data-testid="summary-unknown">
      This summary's source wasn't tracked. Refresh to check it against the current text.
    </p>
  {/if}
</div>
