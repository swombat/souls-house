<script>
  let { rows = [] } = $props();
</script>

{#if rows.length}
  <section class="mb-5 rounded border border-amber-500/50 bg-amber-500/5 p-4" aria-label="Unestimated usage">
    <h3 class="font-semibold">Some recorded usage has no cost estimate</h3>
    <p class="mt-1 text-sm text-muted-foreground">
      Totals exclude these interactions; unavailable does not mean free. Counts below cover all recorded dates.
    </p>
    <ul class="mt-3 space-y-2 text-sm">
      {#each rows as row}
        <li>
          <strong>{row.agent_name}</strong> · {row.model} · {row.interaction_count}
          interaction{row.interaction_count === 1 ? '' : 's'} — {row.reason}
        </li>
      {/each}
    </ul>
  </section>
{/if}
