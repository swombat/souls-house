<script>
  import ActivityBars from '$lib/components/charts/activity-bars.svelte';
  let { title, days, series } = $props();

  const groups = $derived(
    days.map((day) => ({
      key: day.date,
      bars: [
        {
          title: `${day.date}: ${series.map((s) => `${day[s.key]} ${s.label}`).join(', ')}`,
          segments: series.map((s) => ({ value: day[s.key], colour: s.colour })),
        },
      ],
    }))
  );
</script>

<section class="rounded-lg border p-4 space-y-3">
  <h3 class="font-medium">{title}</h3>
  <ActivityBars {groups} label={`${title}, last 14 days. Exact counts in the table below.`} />
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
