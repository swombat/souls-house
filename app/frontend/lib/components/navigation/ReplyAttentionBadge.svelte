<script>
  let { count = 0 } = $props();
</script>

{#if count > 0}
  <span
    class="inline-flex min-w-5 h-5 shrink-0 items-center justify-center rounded-full bg-red-600 px-1 text-xs font-semibold text-white"
    aria-label={`${count} ${count === 1 ? 'thread requests' : 'threads request'} your response`}>
    {count > 99 ? '99+' : count}
  </span>
{/if}
