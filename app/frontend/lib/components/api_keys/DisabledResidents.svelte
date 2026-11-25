<script>
  let { count, children } = $props();
</script>

{#if count > 0}
  <details class="space-y-3">
    <summary class="cursor-pointer text-sm text-muted-foreground">Show {count} disabled</summary>
    {@render children()}
  </details>
{/if}
