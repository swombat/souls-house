<script>
  import { linePoints } from './format.js';

  let {
    values = [],
    width = 120,
    height = 32,
    color = 'currentColor',
    fill = true,
    max = null,
    label = '',
    fluid = false,
  } = $props();

  const segments = $derived(linePoints(values, width, height, { max }));
</script>

<svg
  viewBox={`0 0 ${width} ${height}`}
  width={fluid ? '100%' : width}
  {height}
  class="overflow-visible"
  role="img"
  aria-label={label}
  preserveAspectRatio="none">
  {#each segments as segment}
    {@const tail = segment[segment.length - 1]}
    {#if fill && segment.length > 1}
      <polygon
        points={`${segment[0][0]},${height} ${segment.map((p) => p.join(',')).join(' ')} ${segment[segment.length - 1][0]},${height}`}
        fill={color}
        opacity="0.12" />
    {/if}
    {#if segment.length > 1}
      <polyline
        points={segment.map((p) => p.join(',')).join(' ')}
        fill="none"
        stroke={color}
        stroke-width="1.75"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke" />
    {/if}
    <circle cx={tail[0]} cy={tail[1]} r="2.25" fill={color} />
  {/each}
</svg>
