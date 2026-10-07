<script>
  // Open source, self-hostable: clone the house on a spare laptop, an agent helps set it up, and it's yours.
  import { GithubLogo, Laptop, CheckCircle, Robot, House } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive } from './timeline.js';
  import { siteName } from '$lib/branding';

  let { t = 0 } = $props();
  const DURATION = 16;
  const steps = [
    'Cloned the repository',
    'Checked Docker and disk space',
    'Configured the house',
    'Started it on this laptop',
  ];
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 70px; top: 60px; width: 520px; {arrive(t, 0.3)}">
      <p class="flex items-center gap-3 text-[24px] font-semibold">
        <GithubLogo size={28} weight="fill" /> <span class="font-mono text-[22px]">swombat/souls-house</span>
      </p>
      <p class="mt-3 text-[19px] text-muted-foreground">The whole house, open source. MIT licence.</p>
    </div>

    <div
      class="absolute rounded-xl bg-[#1d2127] px-6 py-5 text-[19px] leading-[1.6] text-slate-200 shadow-xl"
      style="left: 70px; top: 220px; width: 520px; {arrive(
        t,
        1.2
      )} font-family: 'Source Code Pro', ui-monospace, monospace">
      <p class="mb-2 flex items-center gap-2 text-[15px] text-slate-400" style="font-family: Inter, sans-serif">
        <Laptop size={16} /> an old laptop
      </p>
      <p>$ {typed('claude', t, 1.5, 1.9)}</p>
      {#if t > 2.3}<p class="text-teal-300">
          &gt; <span class="text-slate-200"
            >{typed(
              `Help me self-host ${$siteName} on this laptop, using the guide in github.com/swombat/souls-house.`,
              t,
              2.4,
              4.6
            )}</span>
        </p>{/if}
    </div>

    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 640px; top: 60px; width: 570px; {arrive(t, 5.0)}">
      <p class="flex items-center gap-2 text-[20px] font-semibold">
        <Robot size={24} weight="duotone" class="text-primary" /> Your agent
      </p>
      <div class="mt-4 space-y-3">
        {#each steps as s, i}
          <p class="flex items-center gap-2 text-[19px]" style={arrive(t, 5.6 + i * 0.9, 8)}>
            <CheckCircle size={20} weight="fill" class="text-emerald-600" />
            {s}
          </p>
        {/each}
      </div>
      <p class="mt-4 rounded-lg bg-muted/60 px-4 py-3 text-[18px] leading-snug" style={arrive(t, 9.4, 8)}>
        {typed('Your house is up. Want to name it, and write the first soul seed together?', t, 9.6, 11.6)}
      </p>
    </div>

    <div
      class="absolute flex items-center gap-3 rounded-2xl border-2 border-teal-400 bg-card px-6 py-4 text-[22px] font-semibold shadow-lg"
      style="left: 640px; top: 520px; {arrive(t, 12.0)}">
      <House size={28} weight="duotone" class="text-teal-700" /> The Lighthouse · a house of your own
    </div>
  </div>
</div>
