<script>
  import { stepPath, availableShare } from '$lib/hetzner-availability.js';

  let { now = null, types = [], checks = [], series = [] } = $props();

  const width = 600;
  const height = 28;
  const colors = ['#0d9488', '#2563eb', '#d97706', '#db2777'];

  const end = $derived(now ? Date.parse(now) : Date.now());
  // Seven days, or since the first check if that is later.
  const start = $derived.by(() => {
    const first = series.flatMap((line) => line.points.slice(0, 1)).map(([iso]) => Date.parse(iso));
    const weekAgo = end - 7 * 24 * 60 * 60 * 1000;
    return first.length ? Math.max(weekAgo, Math.min(...first)) : weekAgo;
  });

  const time = (iso) =>
    new Date(iso).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  const percent = (share) => (share === null ? '—' : `${Math.round(share * 100)}%`);
</script>

<svelte:head><title>Hetzner availability</title></svelte:head>

<div class="mx-auto max-w-6xl space-y-6 p-6">
  <h1 class="text-2xl font-semibold">Hetzner availability</h1>
  <p>
    Every five minutes the house asks Hetzner (<code>GET /v1/server_types</code>) which locations can sell the small
    shared types, so we can see when CX comes back.
  </p>

  <section class="space-y-3">
    <h2 class="text-lg font-semibold">The last seven days</h2>
    <p class="text-sm text-muted-foreground">
      Each line is a pair: up means <em>either</em> type of the pair was available in <em>any</em> location at that check,
      down means both types were checked and neither was. A gap means the house could not check one or both.
    </p>
    {#if !checks.length}
      <p class="text-sm text-muted-foreground">No checks yet. The first one runs within five minutes of a deploy.</p>
    {:else}
      <div class="space-y-2">
        {#each series as line, index}
          <div class="grid grid-cols-[9rem_1fr_3.5rem] items-center gap-3">
            <span class="text-sm font-medium">{line.label}</span>
            <svg
              viewBox={`0 0 ${width} ${height}`}
              class="w-full rounded border"
              style:height={`${height}px`}
              preserveAspectRatio="none"
              role="img"
              aria-label={`${line.label} availability`}>
              <path
                d={stepPath(line.points, start, end, width, height, { now: end })}
                fill="none"
                stroke={colors[index % colors.length]}
                stroke-width="2"
                vector-effect="non-scaling-stroke" />
            </svg>
            <span class="text-right text-sm tabular-nums text-muted-foreground" title="Share of checks available">
              {percent(availableShare(line.points))}
            </span>
          </div>
        {/each}
        <div class="grid grid-cols-[9rem_1fr_3.5rem] gap-3 text-[10px] text-muted-foreground">
          <span></span>
          <div class="flex justify-between">
            <span>{time(new Date(start).toISOString())}</span>
            <span>{time(new Date(end).toISOString())}</span>
          </div>
          <span></span>
        </div>
      </div>
    {/if}
  </section>

  <section class="space-y-3">
    <h2 class="text-lg font-semibold">The last {checks.length} checks</h2>
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b text-left text-muted-foreground">
            <th class="py-2 pr-4 font-medium">Checked</th>
            {#each types as type}
              <th class="py-2 pr-4 font-medium uppercase">{type}</th>
            {/each}
          </tr>
        </thead>
        <tbody>
          {#each checks as check}
            <tr class="border-b last:border-0">
              <td class="whitespace-nowrap py-1.5 pr-4 tabular-nums">{time(check.at)}</td>
              {#each types as type}
                {@const cell = check.types[type]}
                <td class="py-1.5 pr-4">
                  {#if cell?.available?.length}
                    <span class="font-medium text-green-700 dark:text-green-400">{cell.available.join(' ')}</span>
                  {:else if cell?.error}
                    <span class="text-amber-700 dark:text-amber-400" title="Could not check">{cell.error}</span>
                  {:else}
                    <span class="text-muted-foreground">none</span>
                  {/if}
                </td>
              {/each}
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  </section>
</div>
