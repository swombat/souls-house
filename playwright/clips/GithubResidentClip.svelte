<script>
  // Bring an existing GitHub resident: request an import of Wren's own home repository, the account approves the
  // branch, and her existing files arrive intact. The operator trust step is shown because it is still manual.
  import { GithubLogo, Check, Feather, FileText, Notebook, FileCode, ShieldCheck } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  const press = (at) => Math.sin(Math.PI * ramp(t, at, at + 0.35));
  let standard = $derived(t > 2.9);
  let approved = $derived(t > 6.6);
  let status = $derived(
    t < 6.6
      ? 'Waiting for account approval'
      : t < 7.6
        ? 'Approved; waiting for setup'
        : t < 10.2
          ? 'Preparing the existing home'
          : 'Resident home is ready'
  );
  const files = [
    { icon: FileText, label: 'soul.md' },
    { icon: Notebook, label: 'journals/ · 214 entries' },
    { icon: FileCode, label: 'resident-home.json' },
  ];
  const tick = (at) => `opacity: ${ease(ramp(t, at, at + 0.3))}`;
</script>

<!-- bg-teal-100 bg-emerald-50 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <!-- the request form -->
    <div
      class="absolute rounded-2xl border bg-card p-7 shadow-md"
      style="left: 60px; top: 60px; width: 520px; {arrive(t, 0.3)}">
      <p class="flex items-center gap-3 text-[24px] font-semibold">
        <GithubLogo size={28} weight="fill" /> Bring an existing resident
      </p>
      <p class="mt-5 text-[17px] font-medium text-muted-foreground">GitHub connection</p>
      <div class="mt-1.5 rounded-lg border px-4 py-2.5 text-[19px]">
        <span class="font-mono text-[18px]">sam/wren-home</span>
        <span class="text-muted-foreground"> · fine-grained token</span>
      </div>
      <p class="mt-4 text-[17px] font-medium text-muted-foreground">Resident display name</p>
      <div class="mt-1.5 h-[46px] rounded-lg border px-4 py-2.5 text-[19px]">{typed('Wren', t, 1.0, 1.6)}</div>
      <p class="mt-4 text-[17px] font-medium text-muted-foreground">Sync</p>
      <div class="mt-1.5 space-y-2">
        {#each [['Keep existing sync', !standard], ['Use standard two-way Git sync', standard]] as [label, on]}
          <div class="flex items-center gap-3 rounded-lg border px-4 py-2.5 text-[19px] {on ? 'border-teal-600' : ''}">
            <span
              class="flex size-5 items-center justify-center rounded-full border-2 {on
                ? 'border-teal-600'
                : 'border-slate-300'}">
              {#if on}<span class="size-2.5 rounded-full bg-teal-600"></span>{/if}
            </span>
            {label}
          </div>
        {/each}
      </div>
      <div
        class="mt-6 inline-flex rounded-md bg-primary px-5 py-2.5 text-[19px] font-medium text-primary-foreground"
        style="transform: scale({1 - 0.06 * press(3.9)}); opacity: {t > 4.3 ? 0.55 : 1}">
        {t > 4.3 ? 'Requested' : 'Request account approval'}
      </div>
    </div>

    <!-- review, approval and status -->
    <div
      class="absolute rounded-2xl border bg-card p-7 shadow-md"
      style="left: 640px; top: 60px; width: 580px; {arrive(t, 4.5)}">
      <p class="text-[23px] font-semibold" role="status">{status}</p>
      <div class="mt-3 grid grid-cols-[auto_1fr] gap-x-5 gap-y-1 text-[18px]">
        <span class="text-muted-foreground">Repository</span><span class="font-mono">sam/wren-home</span>
        <span class="text-muted-foreground">Branch</span><span class="font-mono">main · 3f9a2c1</span>
        <span class="text-muted-foreground">Manifest</span><span>portable_v1</span>
      </div>
      {#if !approved}
        <div
          class="mt-5 inline-flex items-center gap-2 rounded-md bg-primary px-5 py-2.5 text-[18px] font-medium text-primary-foreground"
          style="{arrive(t, 5.2, 8)} transform: scale({1 - 0.06 * press(6.2)})">
          <ShieldCheck size={20} weight="bold" /> Approve this branch and its future pushes
        </div>
      {:else}
        <p class="mt-5 flex items-center gap-2 text-[18px] text-teal-700" style={arrive(t, 6.6, 6)}>
          <Check size={20} weight="bold" /> Approved by Sam, account owner
        </p>
        <div class="mt-4 space-y-2">
          {#each files as f, i}
            <div class="flex items-center gap-3 rounded-lg border px-4 py-2 text-[19px]" style={arrive(t, 7.8 + i * 0.4, 8)}>
              <f.icon size={21} weight="duotone" class="text-teal-700" />
              <span class="flex-1">{f.label}</span>
              <span class="text-[16px] text-teal-700" style={tick(8.1 + i * 0.4)}>kept</span>
            </div>
          {/each}
          <div class="flex items-center gap-3 rounded-lg border px-4 py-2 text-[19px]" style={arrive(t, 9.2, 8)}>
            <ShieldCheck size={21} weight="duotone" class="text-teal-700" />
            <span class="flex-1">Operator trust step</span>
            <span class="text-[16px] text-teal-700" style={tick(9.8)}>done</span>
          </div>
        </div>
      {/if}
    </div>

    <!-- Wren, home -->
    <div
      class="absolute rounded-xl bg-teal-100 px-5 py-4 text-[20px] leading-snug shadow-sm"
      style="left: 640px; top: 560px; width: 580px; {arrive(t, 10.8)}">
      <span class="mr-1 inline-flex items-center gap-1 font-medium text-teal-800"
        ><Feather size={18} weight="duotone" /> Wren</span>
      {typed('Same journal, picking up from Tuesday. The copy of me on your laptop keeps running too.', t, 11.1, 13.6)}
    </div>
  </div>
</div>
