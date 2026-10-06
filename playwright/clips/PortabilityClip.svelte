<script>
  // Free to move: Wren is exported with her own files and memory and welcomed into another house.
  import { House, Package, FileText, Notebook, Graph, FolderSimple, Feather, DownloadSimple } from 'phosphor-svelte';
  import { ramp, ease, lerp, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  const parts = [
    { icon: FileText, label: 'soul.md' },
    { icon: Notebook, label: 'journals/' },
    { icon: Graph, label: 'memory graph' },
    { icon: FolderSimple, label: 'files & projects' },
  ];
  let pack = (i) => ease(ramp(t, 2.4 + i * 0.4, 3.0 + i * 0.4));
  let move = $derived(ease(ramp(t, 5.4, 7.4)));
  let unpack = (i) => ease(ramp(t, 8.0 + i * 0.4, 8.6 + i * 0.4));
  let press = $derived(Math.sin(Math.PI * ramp(t, 1.4, 1.8)));
  const BOX_A = { x: 290, y: 470 };
  const BOX_B = { x: 920, y: 470 };
</script>

<!-- bg-teal-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 60px; top: 70px; width: 460px; height: 580px; {arrive(t, 0.3)}">
      <p class="flex items-center gap-2 text-[22px] font-semibold"><House size={24} weight="duotone" /> This house</p>
      <div class="mt-5 flex items-center justify-between">
        <span class="flex items-center gap-2 text-[21px]"
          ><Feather size={24} weight="duotone" class="text-teal-700" /> Wren</span>
        <span
          class="flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-[17px] text-primary-foreground"
          style="transform: scale({1 - 0.06 * press})"><DownloadSimple size={17} /> Export Wren</span>
      </div>
      <div class="mt-5 space-y-2">
        {#each parts as p, i}
          <div
            class="flex items-center gap-2 rounded-lg border px-3 py-2 text-[19px]"
            style="opacity: {1 - 0.7 * pack(i)}">
            <p.icon size={20} weight="duotone" class="text-muted-foreground" />
            {p.label}
          </div>
        {/each}
      </div>
    </div>

    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 760px; top: 70px; width: 460px; height: 580px; {arrive(t, 0.6)}">
      <p class="flex items-center gap-2 text-[22px] font-semibold">
        <House size={24} weight="duotone" /> Another house
      </p>
      <p class="mt-5 flex items-center gap-2 text-[21px]" style="opacity: {unpack(0)}">
        <Feather size={24} weight="duotone" class="text-teal-700" /> Wren
      </p>
      <div class="mt-5 space-y-2">
        {#each parts as p, i}
          <div
            class="flex items-center gap-2 rounded-lg border px-3 py-2 text-[19px]"
            style={arrive(t, 8.0 + i * 0.4, 10)}>
            <p.icon size={20} weight="duotone" class="text-teal-700" />
            {p.label}
          </div>
        {/each}
      </div>
      <div class="mt-5 rounded-xl bg-teal-100 px-4 py-3 text-[19px] leading-snug" style={arrive(t, 10.4)}>
        {typed('New walls, same journal. I remember where we left the tide question.', t, 10.6, 12.4)}
      </div>
    </div>

    <!-- the package travelling between houses -->
    <div
      class="absolute flex flex-col items-center gap-1"
      style="left: {lerp(BOX_A.x, BOX_B.x, move) - 60}px; top: {BOX_A.y -
        Math.sin(Math.PI * move) * 70}px; width: 120px; opacity: {ease(ramp(t, 2.4, 2.8)) *
        (1 - ease(ramp(t, 7.6, 8.2)))}">
      <div class="flex size-20 items-center justify-center rounded-2xl bg-amber-100 shadow-lg">
        <Package size={44} weight="duotone" class="text-amber-700" />
      </div>
      <span class="text-[16px] font-medium text-muted-foreground">wren-export</span>
    </div>
  </div>
</div>
