<script>
  import { usageLine } from '$lib/subscription-usage';
  let { subscription } = $props();
  let usage = $derived(subscription.usage);
  let usageLoading = $derived(subscription.usageLoading);
  let usageError = $derived(subscription.usageError);
  let displayWindows = $derived(subscription.displayWindows);
  const loadUsage = (...args) => subscription.loadUsage(...args);
</script>

<div class="mt-3 space-y-1.5">
  {#if usageLoading && !usage}
    <p class="text-xs text-muted-foreground">Loading subscription usage…</p>
  {:else if usage?.status === 'unknown' || usageError}
    <div class="flex items-center gap-2">
      <p class="text-xs text-muted-foreground">Usage temporarily unavailable</p>
      <button class="text-xs font-medium text-primary hover:underline" type="button" onclick={() => loadUsage(true)}>
        Refresh
      </button>
    </div>
  {:else if displayWindows.length}
    {#each displayWindows as window (window.id)}
      <div
        class={[
          'flex items-center justify-between gap-3 rounded-sm px-2 py-1 text-xs',
          window.blocking && Number(window.remaining_percent) <= 0
            ? 'bg-amber-500/10 text-amber-800 dark:text-amber-300'
            : 'bg-muted/50 text-muted-foreground',
        ]}>
        <span>{usageLine(window)}</span>
      </div>
    {/each}
    <button
      class="text-xs font-medium text-primary hover:underline disabled:opacity-50"
      type="button"
      disabled={usageLoading}
      onclick={() => loadUsage(true)}>
      {usageLoading ? 'Refreshing…' : 'Refresh usage'}
    </button>
  {/if}
</div>
