<script>
  // Tailscale: Wren joins your private tailnet and reaches your own machines over SSH, for work that has to happen there.
  import { Desktop, HardDrives, Cpu, Feather } from 'phosphor-svelte';
  import { ramp, ease, lerp, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  const centre = { x: 360, y: 380 };
  const machines = [
    { name: 'sam-laptop', icon: Desktop, x: 160, y: 200 },
    { name: 'home-nas', icon: HardDrives, x: 560, y: 210 },
    { name: 'studio-pi', icon: Cpu, x: 600, y: 560 },
  ];
  let joined = $derived(ease(ramp(t, 1.6, 2.6)));
  let link = $derived(ease(ramp(t, 4.0, 5.0)));
</script>

<!-- bg-teal-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <p class="absolute left-[70px] top-[40px] text-[22px] font-medium text-muted-foreground">Sam's tailnet</p>
    <div
      class="absolute rounded-full border-2 border-dashed border-slate-300"
      style="left: 60px; top: 90px; width: 640px; height: 580px">
    </div>
    <svg class="absolute inset-0" width="1280" height="720">
      {#each machines as m}
        <line
          x1={lerp(160, centre.x, joined)}
          y1={lerp(620, centre.y, joined)}
          x2={m.x}
          y2={m.y}
          stroke="rgb(148 163 184 / {0.5 * joined})"
          stroke-width="2"
          stroke-dasharray="6 6" />
      {/each}
      <line
        x1={centre.x}
        y1={centre.y}
        x2={lerp(centre.x, machines[1].x, link)}
        y2={lerp(centre.y, machines[1].y, link)}
        stroke="rgb(20 184 166)"
        stroke-width="5"
        stroke-linecap="round" />
    </svg>
    {#each machines as m, i}
      <div
        class="absolute flex flex-col items-center gap-1"
        style="left: {m.x - 70}px; top: {m.y - 34}px; width: 140px; {arrive(t, 0.4 + i * 0.25, 10)}">
        <div class="flex size-14 items-center justify-center rounded-xl border bg-card shadow-sm">
          <m.icon size={30} weight="duotone" />
        </div>
        <span class="font-mono text-[18px]">{m.name}</span>
      </div>
    {/each}
    <div
      class="absolute flex flex-col items-center gap-1"
      style="left: {lerp(160, centre.x, joined) - 70}px; top: {lerp(620, centre.y, joined) -
        34}px; width: 140px; opacity: {ease(ramp(t, 0.8, 1.3))}">
      <div class="flex size-14 items-center justify-center rounded-xl bg-teal-100 shadow-md">
        <Feather size={30} weight="duotone" class="text-teal-700" />
      </div>
      <span class="text-[18px] font-medium text-teal-800">Wren</span>
    </div>

    <div
      class="absolute rounded-xl bg-[#1d2127] px-6 py-5 text-[19px] leading-[1.6] text-slate-200 shadow-xl"
      style="left: 740px; top: 150px; width: 490px; {arrive(
        t,
        4.6
      )} font-family: 'Source Code Pro', ui-monospace, monospace">
      <p><span class="text-teal-300">wren@house</span>:~$ {typed('ssh sam@home-nas', t, 4.9, 5.8)}</p>
      {#if t > 6.4}<p><span class="text-sky-300">sam@home-nas</span>:~$ {typed('df -h /photos', t, 6.5, 7.3)}</p>{/if}
      {#if t > 7.8}
        <p class="whitespace-pre text-slate-400">Size Used Avail Use%</p>
        <p class="whitespace-pre text-slate-400">3.6T 3.4T 204G 95%</p>
      {/if}
    </div>
    <div
      class="absolute rounded-xl bg-teal-100 px-5 py-4 text-[20px] leading-snug shadow-md"
      style="left: 740px; top: 440px; width: 490px; {arrive(t, 9.4)}">
      {typed('The photo drive is 95% full. Want me to move 2019 to the cold disk tonight?', t, 9.6, 12.0)}
    </div>
  </div>
</div>
