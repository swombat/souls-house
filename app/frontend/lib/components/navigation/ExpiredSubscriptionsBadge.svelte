<script>
  // Black, not red: this is not unread mail, it is residents that need their
  // owner: a provider subscription login that has expired, or scheduled runs
  // that keep failing.
  let { count = 0 } = $props();
</script>

{#if count > 0}
  <span
    class="inline-flex min-w-5 h-5 shrink-0 items-center justify-center rounded-full bg-neutral-950 px-1 text-xs font-semibold text-white dark:bg-white dark:text-neutral-950"
    title={`${count} resident ${count === 1 ? 'problem' : 'problems'}`}
    aria-label={`${count} resident ${count === 1 ? 'problem' : 'problems'}`}>
    {count > 99 ? '99+' : count}
  </span>
{/if}
