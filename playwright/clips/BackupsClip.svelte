<script>
  // Backed up every night: a week of nightly snapshots, a bad day, and a restore from the night before.
  import {
    Moon,
    Archive,
    Warning,
    ArrowCounterClockwise,
    CheckCircle,
    FolderSimple,
    Notebook,
    Graph,
    Database,
  } from 'phosphor-svelte';
  import { ramp, ease, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  const nights = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
  const snapAt = (i) => 0.8 + i * 0.9;
  let bad = $derived(ease(ramp(t, 6.0, 6.5)));
  let restore = $derived(ease(ramp(t, 8.6, 9.8)));
  let fixed = $derived(ease(ramp(t, 9.8, 10.3)));
  const items = [
    { icon: FolderSimple, label: 'home' },
    { icon: Notebook, label: 'journals' },
    { icon: Graph, label: 'memory' },
  ];
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <p class="absolute left-[80px] top-[44px] flex items-center gap-2 text-[22px] font-medium text-muted-foreground">
      <Moon size={24} weight="duotone" /> Every night at 03:00
    </p>
    <!-- snapshots row -->
    {#each nights.slice(0, 3) as n, i}
      <div
        class="absolute rounded-xl border bg-card p-4 shadow-sm"
        style="left: {80 + i * 280}px; top: 110px; width: 250px; {arrive(t, snapAt(i), 14)} {i === 2
          ? `box-shadow: 0 0 0 ${4 * restore * (1 - fixed * 0.6)}px rgb(20 184 166 / 0.6)`
          : ''}">
        <p class="flex items-center gap-2 text-[20px] font-semibold">
          <Archive size={20} weight="duotone" class="text-teal-600" />
          {n} night
        </p>
        <p class="mt-2 text-[16px] text-muted-foreground">Wren's home, journals and memory</p>
        <p class="mt-1 flex items-center gap-1.5 text-[16px] text-muted-foreground">
          <Database size={15} /> + the house database
        </p>
      </div>
    {/each}

    <!-- the resident's files, live -->
    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 300px; top: 330px; width: 680px; {arrive(t, 0.4)}">
      <p class="text-[22px] font-semibold">Wren, today (Thursday)</p>
      <div class="mt-5 grid grid-cols-3 gap-4">
        {#each items as it, i}
          {@const broken = i === 1 && bad > 0 && fixed < 1}
          <div
            class="flex items-center gap-2 rounded-lg border p-3 text-[19px]"
            style="border-color: {broken ? `rgb(239 68 68 / ${bad})` : ''}; background: {broken
              ? `rgb(254 226 226 / ${bad})`
              : ''}">
            <it.icon size={22} weight="duotone" class={broken ? 'text-red-600' : 'text-muted-foreground'} />
            {it.label}
            {#if broken}<Warning size={18} class="ml-auto text-red-600" weight="fill" />{/if}
            {#if i === 1 && fixed > 0}<CheckCircle
                size={18}
                class="ml-auto text-teal-600"
                weight="fill"
                style="opacity: {fixed}" />{/if}
          </div>
        {/each}
      </div>
      <p class="mt-5 text-[19px]" style="color: rgb(185 28 28); opacity: {bad * (1 - fixed)}">
        A bad day: a script overwrote half of this week's journal.
      </p>
      <p class="-mt-7 flex items-center gap-2 text-[19px] text-teal-800" style="opacity: {fixed}">
        <ArrowCounterClockwise size={20} /> Restored from Wednesday night. Nothing lost but the bad day.
      </p>
    </div>

    <!-- restore arrow -->
    <svg class="absolute inset-0" width="1280" height="720">
      <path
        d="M 685 250 C 690 300, 640 300, 560 412"
        fill="none"
        stroke="rgb(20 184 166)"
        stroke-width="4"
        stroke-dasharray="500"
        stroke-dashoffset={500 * (1 - restore)}
        stroke-linecap="round" />
    </svg>
  </div>
</div>
