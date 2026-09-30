<script>
  import ActivityBars from '$lib/components/charts/activity-bars.svelte';
  let { days = [] } = $props();
  const charts = [
    {
      label: 'Sessions',
      note: 'Activity runs, including resumed sessions; not unique persistent sessions. Chat includes Telegram. Recorded activity only, UTC days.',
      series: [
        ['heartbeat', 'Heartbeat', 'bg-indigo-300'],
        ['memory', 'Memory', 'bg-indigo-500'],
        ['chat', 'Chat', 'bg-indigo-800'],
        ['other', 'Other', 'bg-slate-400'],
      ],
    },
    {
      label: 'Messages',
      note: 'Resident posts recorded by souls.house; conversation and successfully sent Telegram messages, including media. Excludes incoming messages and system notices. Direct Telegram calls outside souls.house are not tracked. UTC days.',
      series: [
        ['conversation', 'Conversation', 'bg-emerald-500'],
        ['telegram', 'Telegram', 'bg-sky-500'],
      ],
    },
  ];
  const total = (day, series) => series.reduce((sum, [key]) => sum + (day[key] || 0), 0);
</script>

<div class="space-y-3 mb-4">
  {#each charts as chart}
    {@const groups = days.map((day) => ({
      key: day.date,
      bars: [
        {
          title: `${day.date}: ${chart.series.map(([key, label]) => `${label} ${day[key] || 0}`).join(' · ')}`,
          segments: chart.series.map(([key, label, colour]) => ({ value: day[key] || 0, colour })),
        },
      ],
    }))}
    <div>
      <div class="flex items-center justify-between text-[10px] text-muted-foreground mb-1" title={chart.note}>
        <span class="font-medium">{chart.label} · {days.reduce((sum, day) => sum + total(day, chart.series), 0)}</span>
        <span>14 days · UTC</span>
      </div>
      <ActivityBars
        {groups}
        class="h-9 border-b"
        barClass="bg-muted/30 rounded-t-sm overflow-hidden"
        label={`${chart.label} over the last 14 days. ${chart.note}`} />
      <div class="flex flex-wrap gap-x-2 gap-y-0.5 mt-1 text-[9px] text-muted-foreground">
        {#each chart.series as [key, label, colour]}
          {#if key !== 'other' || days.some((day) => day.other > 0)}
            <span class="inline-flex items-center gap-1"
              ><span class="size-1.5 rounded-sm {colour}"></span>{label}</span>
          {/if}
        {/each}
      </div>
    </div>
  {/each}
</div>
