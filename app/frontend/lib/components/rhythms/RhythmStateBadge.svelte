<script>
  let { state = 'active', holdCount = 0 } = $props();
</script>

{#if state === 'paused'}
  <span
    class="inline-flex items-center gap-1 rounded-full border border-amber-300 bg-amber-50 px-2.5 py-0.5 text-xs font-medium text-amber-800 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300">
    Paused{holdCount > 1 ? ` · ${holdCount} holds` : ''}
  </span>
{:else}
  <span
    class="inline-flex items-center gap-1 rounded-full border border-emerald-300 bg-emerald-50 px-2.5 py-0.5 text-xs font-medium text-emerald-800 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-300">
    Active
  </span>
{/if}
