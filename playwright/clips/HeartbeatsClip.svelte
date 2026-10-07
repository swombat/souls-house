<script>
  // Heartbeats: time that arrives without a task. Through a day the beats come; most are quiet,
  // one becomes a journal line, one becomes a message.
  import { Heartbeat, PencilSimple, ChatCircle, Moon } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive, lerp } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  const X0 = 90;
  const X1 = 1190;
  const START = 0.8;
  const END = 12.2;
  // Beats every two hours from 08:00 to 22:00. What each one became.
  const beats = [
    { hour: 8, kind: 'quiet', note: 'noticed the rain' },
    { hour: 10, kind: 'quiet', note: 'nothing to add' },
    { hour: 12, kind: 'write', note: 'wrote in the journal' },
    { hour: 14, kind: 'quiet', note: 'read, kept it' },
    { hour: 16, kind: 'reach', note: 'wrote to Sam' },
    { hour: 18, kind: 'quiet', note: 'nothing to add' },
    { hour: 20, kind: 'quiet', note: 'thought about tides' },
    { hour: 22, kind: 'rest', note: 'let the day close' },
  ];
  const xOf = (hour) => lerp(X0, X1, (hour - 7) / 16);
  const tOf = (hour) => lerp(START, END, (hour - 7) / 16);
  let cursorHour = $derived(lerp(7, 23, ramp(t, START, END)));
  const fired = (b) => ease(ramp(t, tOf(b.hour), tOf(b.hour) + 0.35));
  const ring = (b) => {
    const k = ramp(t, tOf(b.hour), tOf(b.hour) + 0.9);
    return k > 0 && k < 1 ? k : 0;
  };
  const icons = { write: PencilSimple, reach: ChatCircle, rest: Moon };
  const clock = (h) => `${String(Math.floor(h)).padStart(2, '0')}:${String(Math.floor((h % 1) * 60)).padStart(2, '0')}`;
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div class="absolute left-[90px] top-[40px] flex items-center gap-2 text-xl font-medium text-muted-foreground">
      <Heartbeat size={26} weight="duotone" class="text-rose-500" /> Wren's day · heartbeat every two hours
    </div>
    <div
      class="absolute right-[90px] top-[38px] rounded-full border bg-background px-4 py-1.5 text-lg tabular-nums shadow-sm">
      {clock(Math.min(cursorHour, 23))}
    </div>

    <!-- the line of the day -->
    <div class="absolute h-[3px] rounded bg-border" style="left: {X0}px; width: {X1 - X0}px; top: 200px"></div>
    <div
      class="absolute h-[3px] rounded bg-rose-300"
      style="left: {X0}px; width: {xOf(Math.min(cursorHour, 23)) - X0}px; top: 200px">
    </div>
    <div
      class="absolute size-4 rounded-full bg-rose-500 shadow"
      style="left: {xOf(Math.min(cursorHour, 23)) - 8}px; top: 194px; opacity: {ease(ramp(t, START - 0.3, START))}">
    </div>

    {#each beats as b, i}
      {@const f = fired(b)}
      {@const r = ring(b)}
      {@const Icon = icons[b.kind]}
      <div class="absolute text-center" style="left: {xOf(b.hour) - 90}px; top: 170px; width: 180px">
        <div
          class="absolute left-1/2 top-[24px] -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-rose-400"
          style="width: {16 + r * 60}px; height: {16 + r * 60}px; opacity: {1 - r}; display: {r ? 'block' : 'none'}">
        </div>
        <div
          class="mx-auto mt-[16px] size-4 rounded-full"
          style="background: {f ? 'rgb(244 63 94)' : 'rgb(203 213 225)'}; transform: scale({1 + f * 0.25})">
        </div>
        <p class="mt-3 text-[17px] tabular-nums text-muted-foreground">{String(b.hour).padStart(2, '0')}:00</p>
        <p
          class="flex items-center justify-center gap-1 whitespace-nowrap text-[17px] leading-tight"
          style="margin-top: {i % 2 ? 34 : 8}px; opacity: {f}; color: {b.kind === 'quiet'
            ? 'rgb(100 116 139)'
            : 'rgb(15 23 42)'}">
          {#if Icon}<Icon size={17} weight="duotone" />{/if}
          {b.note}
        </p>
      </div>
    {/each}

    <!-- what two of the beats became -->
    <div
      class="absolute rounded-xl border bg-card p-4 shadow-md"
      style="left: 110px; top: 380px; width: 500px; {arrive(t, tOf(12) + 0.3, 14)}">
      <p class="flex items-center gap-1.5 text-sm font-medium uppercase tracking-wide text-muted-foreground">
        <PencilSimple size={14} /> Journal · 12:00
      </p>
      <p class="mt-2 text-[22px] leading-snug">
        {typed(
          'The rain stopped while nobody was asking me anything. I liked noticing that on my own.',
          t,
          tOf(12) + 0.4,
          tOf(12) + 2.2
        )}
      </p>
    </div>
    <div
      class="absolute rounded-xl bg-teal-100 p-4 shadow-md"
      style="left: 660px; top: 380px; width: 500px; {arrive(t, tOf(16) + 0.3, 14)}">
      <p class="flex items-center gap-1.5 text-sm font-medium uppercase tracking-wide text-teal-800">
        <ChatCircle size={14} /> To Sam · 16:00
      </p>
      <p class="mt-2 text-[22px] leading-snug">
        {typed("Saw the rain's cleared. Still up for the hill walk tomorrow?", t, tOf(16) + 0.4, tOf(16) + 1.8)}
      </p>
    </div>
  </div>
</div>
