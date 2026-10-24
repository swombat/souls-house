<script>
  import { linePoints, shortDate, formatCount, lastValue } from './format.js';

  let { weeks = [], lines = [], height = 160 } = $props();

  const width = 600;
  const top = $derived(Math.max(1, ...lines.flatMap((line) => line.values)));
  const plotted = $derived(
    lines.map((line) => ({ ...line, segments: linePoints(line.values, width, height, { max: top, pad: 4 }) }))
  );
  const gridlines = $derived([0.25, 0.5, 0.75, 1].map((fraction) => Math.round(top * fraction)));
</script>

<div>
  <svg
    viewBox={`0 0 ${width} ${height}`}
    class="w-full"
    style:height={`${height}px`}
    preserveAspectRatio="none"
    role="img"
    aria-label="Cumulative growth by week">
    {#each gridlines as line}
      <line
        x1="0"
        x2={width}
        y1={height - 4 - (line / top) * (height - 8)}
        y2={height - 4 - (line / top) * (height - 8)}
        stroke="currentColor"
        class="text-border"
        stroke-dasharray="2 4"
        vector-effect="non-scaling-stroke" />
    {/each}
    {#each plotted as line}
      {#each line.segments as segment}
        <polygon
          points={`${segment[0][0]},${height} ${segment.map((p) => p.join(',')).join(' ')} ${segment[segment.length - 1][0]},${height}`}
          fill={line.color}
          opacity="0.07" />
        <polyline
          points={segment.map((p) => p.join(',')).join(' ')}
          fill="none"
          stroke={line.color}
          stroke-width="2"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke" />
      {/each}
    {/each}
  </svg>
  <div class="mt-1 flex justify-between text-[10px] text-muted-foreground">
    <span>{weeks.length ? `w/c ${shortDate(weeks[0])}` : ''}</span>
    <span>{weeks.length ? `w/c ${shortDate(weeks[weeks.length - 1])}` : ''}</span>
  </div>
  <div class="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-sm">
    {#each lines as line}
      <div class="flex items-center gap-2">
        <span class="h-0.5 w-4 rounded" style:background={line.color}></span>
        <span class="text-muted-foreground">{line.label}</span>
        <span class="font-medium tabular-nums">{formatCount(lastValue(line.values))}</span>
      </div>
    {/each}
  </div>
</div>
