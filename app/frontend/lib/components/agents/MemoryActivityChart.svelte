<script>
  let { title, days, series } = $props();
  let maximum = $derived(Math.max(1, ...days.map((day) => series.reduce((sum, entry) => sum + day[entry.key], 0))));
</script>

<section class="rounded-lg border p-4 space-y-3">
  <h3 class="font-medium">{title}</h3>
  <div
    class="flex items-end gap-1 h-32"
    role="img"
    aria-label={`${title}, last 14 days. Exact counts in the table below.`}>
    {#each days as day}
      <div
        class="flex h-full flex-1 flex-col justify-end"
        title={`${day.date}: ${series.map((s) => `${day[s.key]} ${s.label}`).join(', ')}`}>
        {#each series as entry}
          <div class={entry.colour} style:height={`${(day[entry.key] / maximum) * 100}%`}></div>
        {/each}
        <div class="border-t border-muted-foreground/30"></div>
      </div>
    {/each}
  </div>
  <div class="flex justify-between text-xs text-muted-foreground">
    <span>{days[0]?.date}</span><span>{days.at(-1)?.date}</span>
  </div>
  <div class="flex gap-4 text-sm">
    {#each series as entry}
      <span class="flex items-center gap-1"
        ><span class={`inline-block h-3 w-3 rounded-sm ${entry.colour}`}></span>{entry.label}</span>
    {/each}
  </div>
  <details class="text-sm">
    <summary class="cursor-pointer">Daily counts</summary>
    <table class="w-full mt-2 text-left">
      <thead
        ><tr
          ><th>Date</th>{#each series as entry}<th>{entry.label}</th>{/each}</tr
        ></thead>
      <tbody
        >{#each days as day}<tr
            ><th class="font-normal">{day.date}</th>{#each series as entry}<td>{day[entry.key]}</td>{/each}</tr
          >{/each}</tbody>
    </table>
  </details>
</section>
