<script>
  import Table from './table.svelte';
  let { element } = $props();
  let props = $derived(element.props);
  const colors = [
    'text-blue-600 dark:text-blue-400',
    'text-orange-600 dark:text-orange-400',
    'text-emerald-600 dark:text-emerald-400',
    'text-fuchsia-600 dark:text-fuchsia-400',
    'text-cyan-700 dark:text-cyan-300',
    'text-rose-600 dark:text-rose-400',
    'text-violet-600 dark:text-violet-400',
    'text-amber-700 dark:text-amber-300',
  ];
  // Normalize first to keep coordinates finite even for very large finite values.
  let scale = $derived(Math.max(1, ...props.series.flatMap((series) => series.values.map(Math.abs))));
  let low = $derived(Math.min(0, ...props.series.flatMap((series) => series.values.map((value) => value / scale))));
  let high = $derived(Math.max(0, ...props.series.flatMap((series) => series.values.map((value) => value / scale))));
  let range = $derived(high - low || 1);
  const x = (index) => 60 + ((index + 0.5) / props.labels.length) * 520;
  const y = (value) => 230 - ((value / scale - low) / range) * 200;
  let data = $derived({
    props: {
      title: `${props.title || 'Chart'} data`,
      columns: ['Label', ...props.series.map((series) => series.name)],
      rows: props.labels.map((label, index) => [label, ...props.series.map((series) => series.values[index])]),
    },
  });
</script>

<figure class="min-w-0 space-y-3">
  <figcaption class="font-semibold">{props.title || (props.kind === 'line' ? 'Line chart' : 'Bar chart')}</figcaption>
  <svg
    viewBox="0 0 600 280"
    class="h-auto w-full text-foreground"
    role="img"
    aria-label={`${props.title || props.kind + ' chart'}. ${props.labels.length} labels, ${props.series.length} series. Exact values in the data table below.`}>
    <title>{props.title || 'Chart'}</title>
    <desc>Series: {props.series.map((series) => series.name).join(', ')}. A data table follows this chart.</desc>
    <line x1="60" x2="580" y1={y(0)} y2={y(0)} stroke="currentColor" opacity="0.4" />
    <text x="55" y="32" text-anchor="end" fill="currentColor" font-size="10">{(high * scale).toPrecision(3)}</text>
    <text x="55" y="230" text-anchor="end" fill="currentColor" font-size="10">{(low * scale).toPrecision(3)}</text>
    {#each props.series as series, seriesIndex}
      <g class={colors[seriesIndex]}>
        {#if props.kind === 'line'}
          <polyline
            points={series.values.map((value, index) => `${x(index)},${y(value)}`).join(' ')}
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-dasharray={seriesIndex % 2 ? '6 3' : 'none'} />
          {#each series.values as value, index}
            <circle cx={x(index)} cy={y(value)} r="2.5" fill="currentColor">
              <title>{series.name}: {props.labels[index]} = {value}</title>
            </circle>
          {/each}
        {:else}
          {#each series.values as value, index}
            {@const groupWidth = 520 / props.labels.length}
            {@const width = (groupWidth * 0.8) / props.series.length}
            <rect
              x={x(index) - groupWidth * 0.4 + width * seriesIndex}
              y={Math.min(y(value), y(0))}
              width={width * 0.9}
              height={Math.abs(y(value) - y(0))}
              fill="currentColor">
              <title>{series.name}: {props.labels[index]} = {value}</title>
            </rect>
          {/each}
        {/if}
      </g>
    {/each}
    {#each props.labels as label, index}
      {#if index % Math.max(1, Math.ceil(props.labels.length / 6)) === 0 || index === props.labels.length - 1}
        <text x={x(index)} y="255" text-anchor="middle" fill="currentColor" font-size="10">
          {label.length > 14 ? label.slice(0, 14) + '…' : label}
        </text>
      {/if}
    {/each}
  </svg>
  <ul class="flex flex-wrap gap-x-4 gap-y-1 text-sm" aria-label="Chart legend">
    {#each props.series as series, index}
      <li class={colors[index]}>
        <span aria-hidden="true">{props.kind === 'line' && index % 2 ? '┄' : '━'}</span>
        {series.name}
      </li>
    {/each}
  </ul>
  <details>
    <summary class="cursor-pointer text-sm underline">View chart data table</summary>
    <Table element={data} />
  </details>
</figure>
