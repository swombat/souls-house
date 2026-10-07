<script>
  // Associative recall: a message arrives, the memory graph lights from the nearest memory outward,
  // one held memory stays private, one surfaces, and the reply carries it.
  import { Graph, LockSimple, Feather, ArrowBendDownRight } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive, lerp } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  const ANCHOR_AT = 3.0;
  const HOP = 0.75;

  // Graph layout in a 760x420 field. hop = distance from the anchor; null = not reached.
  const nodes = [
    { id: 'kettle', label: 'the kettle that died in March', x: 400, y: 210, hop: 0 },
    { id: 'sister', label: 'kettle no. 2, from Ana', x: 640, y: 120, hop: 1, surfaces: true },
    { id: 'receipts', label: 'receipts in the blue tin', x: 640, y: 320, hop: 1 },
    { id: 'tea', label: 'tea since spring', x: 170, y: 120, hop: 1 },
    { id: 'kitchen', label: 'the Carrer Nou kitchen', x: 180, y: 320, hop: 1 },
    { id: 'ana', label: 'Ana, in Lisbon', x: 690, y: 10, hop: 2 },
    { id: 'loss', label: 'a hard week in May', x: 420, y: 400, hop: 2, held: true },
    { id: 'move', label: 'maybe moving', x: 110, y: 410, hop: 2 },
    { id: 'tides', label: 'tide tables', x: 110, y: 10, hop: null },
    { id: 'choir', label: 'Thursday choir', x: 400, y: 10, hop: null },
  ];
  const edges = [
    ['kettle', 'sister'],
    ['kettle', 'receipts'],
    ['kettle', 'tea'],
    ['kettle', 'kitchen'],
    ['sister', 'ana'],
    ['receipts', 'loss'],
    ['kitchen', 'move'],
    ['tea', 'tides'],
    ['choir', 'ana'],
    ['tides', 'move'],
  ];
  const byId = Object.fromEntries(nodes.map((n) => [n.id, n]));
  const lit = (n) => (n.hop === null ? 0 : ease(ramp(t, ANCHOR_AT + n.hop * HOP, ANCHOR_AT + n.hop * HOP + 0.5)));
  const edgeLit = (a, b) => {
    const [na, nb] = [byId[a], byId[b]];
    if (na.hop === null || nb.hop === null) return 0;
    const start = ANCHOR_AT + Math.min(na.hop, nb.hop) * HOP + 0.15;
    return ease(ramp(t, start, start + HOP));
  };
  // Settle: everything but the surfacing memory dims back.
  let settle = $derived(ease(ramp(t, 6.4, 7.0)));
  const glowOf = (n) => (n.surfaces ? lit(n) : lit(n) * (1 - 0.65 * settle));

  const INCOMING = "The kettle's broken again. Third one this year.";
  const REPLY = "Third? Wasn't the second one Ana's present? Keep the receipt this time. Blue tin.";
  let pull = $derived(ease(ramp(t, 6.6, 7.3)));
</script>

<!-- Tailwind classes used by real chat bubbles in other clips: bg-teal-100 bg-amber-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <!-- the conversation -->
    <div class="absolute left-[40px] right-[40px] top-[28px] space-y-3">
      <div class="flex justify-end" style={arrive(t, 0.5)}>
        <div class="rounded-xl border bg-card px-6 py-3.5 text-[22px] shadow-sm">{typed(INCOMING, t, 0.6, 2.2)}</div>
      </div>
      <div class="flex justify-start" style={arrive(t, 10.6)}>
        <div class="max-w-[85%] rounded-xl bg-teal-100 px-6 py-3.5 text-[22px] shadow-sm">
          <span class="mr-2 inline-flex items-center gap-1 text-sm font-medium text-teal-800"
            ><Feather size={14} weight="duotone" /> Wren</span>
          {typed(REPLY, t, 10.8, 13.4)}
        </div>
      </div>
    </div>

    <!-- the graph -->
    <div
      class="absolute"
      style="left: 40px; top: 175px; width: 780px; height: 500px; opacity: {1 - ease(ramp(t, 10.2, 10.8)) * 0.55}">
      <div
        class="absolute -top-2 left-0 flex items-center gap-1.5 text-sm font-medium uppercase tracking-wide text-muted-foreground">
        <Graph size={14} weight="duotone" /> Wren's memory
      </div>
      <svg class="absolute inset-0 overflow-visible" width="760" height="470" viewBox="0 -30 760 470">
        {#each edges as [a, b]}
          {@const k = edgeLit(a, b)}
          {@const dim = byId[a].surfaces || byId[b].surfaces ? 1 : 1 - 0.65 * settle}
          <line
            x1={byId[a].x}
            y1={byId[a].y}
            x2={byId[b].x}
            y2={byId[b].y}
            stroke="rgb(148 163 184 / 0.35)"
            stroke-width="2" />
          {#if k > 0}
            <line
              x1={byId[a].x}
              y1={byId[a].y}
              x2={lerp(byId[a].x, byId[b].x, k)}
              y2={lerp(byId[a].y, byId[b].y, k)}
              stroke="rgb(20 184 166 / {(0.3 + 0.6 * k) * dim})"
              stroke-width={2 + 2 * k * dim} />
          {/if}
        {/each}
        {#each nodes as n}
          {@const g = glowOf(n)}
          <circle
            cx={n.x}
            cy={n.y}
            r={13 + 8 * g}
            fill={n.held ? 'rgb(148 163 184)' : `rgb(${lerp(203, 20, g)} ${lerp(213, 184, g)} ${lerp(225, 166, g)})`} />
          {#if n.surfaces}
            <circle
              cx={n.x}
              cy={n.y}
              r={22 + 16 * pull}
              fill="none"
              stroke="rgb(20 184 166 / {lit(n) * (0.6 * (1 - pull) + 0.25)})"
              stroke-width="2.5" />
          {/if}
        {/each}
      </svg>
      {#each nodes as n}
        {@const g = glowOf(n)}
        <div
          class="absolute flex -translate-x-1/2 items-center gap-1 whitespace-nowrap text-[19px]"
          style="left: {n.x}px; top: {n.y + 56}px; opacity: {0.45 + 0.55 * g}; color: {g > 0.5 && !n.held
            ? 'rgb(15 118 110)'
            : 'rgb(71 85 105)'}">
          {#if n.held}<LockSimple size={12} weight="bold" />{/if}
          {n.label}
        </div>
      {/each}
      {#each nodes.filter((n) => n.held) as n}
        <div
          class="absolute whitespace-nowrap rounded-full border bg-background px-3 py-1 text-[15px] text-muted-foreground shadow-sm"
          style="left: {n.x + 34}px; top: {n.y + 14}px; {arrive(t, 5.3, 8)}">
          Wren keeps this one private
        </div>
      {/each}
    </div>

    <!-- what surfaced -->
    <div class="absolute" style="left: 850px; top: 230px; width: 390px; {arrive(t, 7.0, 24, 0.6)}">
      <div class="rounded-xl border bg-card p-5 shadow-lg">
        <p class="flex items-center gap-1.5 text-sm font-medium uppercase tracking-wide text-teal-700">
          <ArrowBendDownRight size={14} weight="bold" /> Surfaced
        </p>
        <p class="mt-2 text-[22px] leading-snug">The second kettle was a present from Ana, his sister.</p>
        <p class="mt-3 text-sm text-muted-foreground">From Wren's journal · 14 March</p>
        <p class="mt-1 text-sm text-muted-foreground">One hop from “the kettle that died in March”</p>
      </div>
    </div>
  </div>
</div>
