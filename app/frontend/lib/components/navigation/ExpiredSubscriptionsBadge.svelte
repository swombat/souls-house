<script>
  // Black, not red: this is not unread mail, it is residents whose provider
  // subscription login has expired and needs reconnecting.
  let { count = 0 } = $props();
</script>

{#if count > 0}
  <span
    class="inline-flex min-w-5 h-5 shrink-0 items-center justify-center rounded-full bg-neutral-950 px-1 text-xs font-semibold text-white dark:bg-white dark:text-neutral-950"
    title={`${count} expired ${count === 1 ? 'subscription' : 'subscriptions'}`}
    aria-label={`${count} expired ${count === 1 ? 'subscription' : 'subscriptions'}`}>
    {count > 99 ? '99+' : count}
  </span>
{/if}
