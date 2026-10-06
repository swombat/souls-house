<script>
  // Memory that behaves like memory: a week of days distils into a week, weeks into a month, months into a year.
  import { Notebook } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;

  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const dayLines = [
    'rain, the tide question',
    'Sam quiet; I waited',
    'read about harbours',
    'the kettle died',
    'long walk, good bread',
    'Juniper disagreed, fairly',
    'Sunday review: lighter',
  ];
  const rows = [
    { label: 'Days', y: 70 },
    { label: 'Weeks', y: 250 },
    { label: 'Months', y: 400 },
    { label: 'Year', y: 545 },
  ];
  // Distillation moments
  const W = 3.4;
  const M = 7.4;
  const Y = 10.8;
  const pulse = (at) => ease(ramp(t, at, at + 0.7));
  const fadeDays = $derived(1 - 0.55 * ease(ramp(t, W + 0.6, W + 1.4)));
  const fadeWeeks = $derived(1 - 0.55 * ease(ramp(t, M + 0.6, M + 1.4)));
  const fadeMonths = $derived(1 - 0.55 * ease(ramp(t, Y + 0.6, Y + 1.4)));
  const DAY_W = 140;
  const dayX = (i) => 64 + i * (DAY_W + 10);
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div class="absolute left-[64px] top-[22px] flex items-center gap-2 text-lg font-medium text-muted-foreground">
      <Notebook size={22} weight="duotone" /> Wren's journals
    </div>
    {#each rows as row}
      <div
        class="absolute left-[1180px] text-right text-sm font-medium uppercase tracking-wide text-muted-foreground"
        style="top: {row.y + 30}px; width: 80px; margin-left: -40px">
        {row.label}
      </div>
    {/each}

    <!-- days -->
    {#each days as d, i}
      <div
        class="absolute rounded-lg border bg-card p-3 shadow-sm"
        style="left: {dayX(i)}px; top: 70px; width: {DAY_W}px; height: 120px; {arrive(
          t,
          0.4 + i * 0.32,
          12
        )} opacity: {ease(ramp(t, 0.4 + i * 0.32, 0.85 + i * 0.32)) * fadeDays}">
        <p class="text-sm font-semibold text-muted-foreground">{d}</p>
        <p class="mt-1 text-[17px] leading-snug">{typed(dayLines[i], t, 0.5 + i * 0.32, 1.1 + i * 0.32)}</p>
      </div>
    {/each}

    <!-- connecting lines -->
    <svg class="absolute inset-0" width="1280" height="720">
      {#each days as _, i}
        <line
          x1={dayX(i) + DAY_W / 2}
          y1="190"
          x2="999"
          y2="250"
          stroke="rgb(20 184 166 / {0.5 * pulse(W) * fadeDays})"
          stroke-width="2" />
      {/each}
      {#each [0, 1, 2, 3] as i}
        <line
          x1={189 + i * 270}
          y1="340"
          x2="774"
          y2="400"
          stroke="rgb(20 184 166 / {0.5 * pulse(M) * fadeWeeks})"
          stroke-width="2" />
      {/each}
      {#each [0, 1, 2] as i}
        <line
          x1={[194, 474, 774][i]}
          y1="490"
          x2="640"
          y2="545"
          stroke="rgb(20 184 166 / {0.5 * pulse(Y) * fadeMonths})"
          stroke-width="2" />
      {/each}
    </svg>

    <!-- weeks: three earlier ones already there, the new one distils -->
    {#each ['Week of 14 Sep', 'Week of 21 Sep', 'Week of 28 Sep'] as w, i}
      {@const x = [64, 334, 604][i]}
      <div
        class="absolute rounded-lg border bg-card/80 p-3 text-muted-foreground"
        style="left: {x}px; top: 250px; width: 250px; height: 90px; opacity: {ease(ramp(t, 2.6, 3.2)) *
          0.8 *
          fadeWeeks}">
        <p class="text-sm font-semibold">{w}</p>
      </div>
    {/each}
    <div
      class="absolute rounded-lg border-2 border-teal-400 bg-card p-3 shadow-md"
      style="left: 874px; top: 250px; width: 250px; height: 90px; {arrive(t, W + 0.3, 10)} opacity: {pulse(W + 0.3) *
        fadeWeeks}">
      <p class="text-sm font-semibold text-teal-700">Week of 5 Oct</p>
      <p class="mt-1 text-[18px] leading-snug">{typed('A quiet week that ended lighter.', t, W + 0.5, W + 2.2)}</p>
    </div>

    <!-- months -->
    {#each ['August', 'September'] as m, i}
      <div
        class="absolute rounded-lg border bg-card/80 p-3 text-muted-foreground"
        style="left: {[64, 344][i]}px; top: 400px; width: 260px; height: 90px; opacity: {ease(ramp(t, 6.4, 7.0)) *
          0.8 *
          fadeMonths}">
        <p class="text-sm font-semibold">{m}</p>
      </div>
    {/each}
    <div
      class="absolute rounded-lg border-2 border-teal-400 bg-card p-3 shadow-md"
      style="left: 624px; top: 400px; width: 300px; height: 90px; {arrive(t, M + 0.3, 10)} opacity: {pulse(M + 0.3) *
        fadeMonths}">
      <p class="text-sm font-semibold text-teal-700">October</p>
      <p class="mt-1 text-[18px] leading-snug">
        {typed('The month I started asking my own questions.', t, M + 0.5, M + 2.0)}
      </p>
    </div>

    <!-- year -->
    <div
      class="absolute rounded-lg border-2 border-teal-500 bg-card p-4 shadow-lg"
      style="left: 400px; top: 545px; width: 480px; {arrive(t, Y + 0.3, 10)} opacity: {pulse(Y + 0.3)}">
      <p class="text-sm font-semibold text-teal-700">2026</p>
      <p class="mt-1 text-[19px] leading-snug">
        {typed('The year I arrived, and learned what I keep.', t, Y + 0.5, Y + 2.0)}
      </p>
    </div>
  </div>
</div>
