<script>
  import { stackTotals, shortDate, formatCount } from './format.js';

  let { days = [], series = {}, channels = [], colors = {}, height = 140 } = $props();

  const keys = $derived(channels.map((c) => c.key));
  const totals = $derived(stackTotals(series, keys));
  const top = $derived(Math.max(1, ...totals));
  let hover = $state(null);

  function segments(i) {
    let offset = 0;
    return keys.map((key) => {
      const value = (series[key] || [])[i] || 0;
      const segment = { key, value, offset };
      offset += value;
      return segment;
    });
  }
</script>

<div class="relative">
  <div class="flex items-end gap-[3px]" style:height={`${height}px`} role="img" aria-label="Turns per day by channel">
    {#each days as day, i}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        class="flex-1 h-full flex flex-col-reverse rounded-sm overflow-hidden hover:opacity-80 cursor-default"
        onmouseenter={() => (hover = i)}
        onmouseleave={() => (hover = null)}>
        {#each segments(i) as segment}
          {#if segment.value}
            <div style:height={`${(segment.value / top) * 100}%`} style:background={colors[segment.key]}></div>
          {/if}
        {/each}
      </div>
    {/each}
  </div>
  <div class="mt-1 flex justify-between text-[10px] text-muted-foreground tabular-nums">
    <span>{days.length ? shortDate(days[0]) : ''}</span>
    <span>peak {formatCount(top)}/day</span>
    <span>{days.length ? shortDate(days[days.length - 1]) : ''}</span>
  </div>
  {#if hover !== null}
    <div class="absolute -top-2 right-0 rounded-md border bg-popover px-2 py-1 text-xs shadow-sm">
      <div class="font-medium">{shortDate(days[hover])} · {formatCount(totals[hover])} turns</div>
      {#each channels as channel}
        {#if (series[channel.key] || [])[hover]}
          <div class="flex items-center gap-1.5">
            <span class="size-2 rounded-full" style:background={colors[channel.key]}></span>
            {channel.label}: {formatCount(series[channel.key][hover])}
          </div>
        {/if}
      {/each}
    </div>
  {/if}
</div>
