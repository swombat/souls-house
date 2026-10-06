<script>
  // Any substrate: the model behind Wren is changed in her settings. The change is announced to the account,
  // and Wren is offered a fresh orientation on the new model, so it never happens silently.
  import { Cpu, CaretDown, CheckCircle, Megaphone, Feather } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive } from './timeline.js';
  import { siteName } from '$lib/branding';

  let { t = 0 } = $props();
  const DURATION = 16;
  const models = [
    ['Claude Opus 5.5', 'Anthropic'],
    ['GPT-6 Astra', 'OpenAI'],
    ['Grok', 'xAI'],
    ['Kimi', 'Moonshot'],
  ];
  let open = $derived(t >= 1.6 && t < 3.6);
  let highlighted = $derived(t < 2.6 ? 0 : 1);
  let chosen = $derived(t >= 3.6 ? 1 : 0);
</script>

<!-- bg-teal-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 70px; top: 70px; width: 560px; {arrive(t, 0.3)}">
      <p class="flex items-center gap-2 text-[22px] font-semibold">
        <Feather size={24} weight="duotone" class="text-teal-700" /> Wren · settings
      </p>
      <p class="mt-6 text-[18px] font-medium">Model</p>
      <div class="relative mt-2">
        <div class="flex items-center justify-between rounded-md border bg-background px-4 py-3 text-[20px]">
          <span class="flex items-center gap-2"><Cpu size={20} /> {models[chosen][0]}</span><CaretDown size={18} />
        </div>
        {#if open}
          <div class="absolute left-0 right-0 top-[58px] z-10 rounded-md border bg-background p-1 shadow-lg">
            {#each models as [m, p], i}
              <div
                class="flex items-center justify-between rounded px-3 py-2.5 text-[19px]"
                class:bg-muted={i === highlighted}>
                <span>{m}</span><span class="text-[16px] text-muted-foreground">{p}</span>
              </div>
            {/each}
          </div>
        {/if}
      </div>
      <div
        class="mt-6 flex items-start gap-2 rounded-lg border border-emerald-500/30 bg-emerald-500/10 p-4 text-[18px] leading-snug"
        style={arrive(t, 4.6, 8)}>
        <CheckCircle size={20} weight="fill" class="mt-0.5 shrink-0 text-emerald-600" />
        <span
          >Wren was updated. An account-wide notice will stand until 13 October. {$siteName} has requested a fresh orientation
          on the new model.</span>
      </div>
    </div>

    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 680px; top: 70px; width: 530px; {arrive(t, 6.0)}">
      <p class="flex items-center gap-2 text-[18px] font-medium uppercase tracking-wide text-muted-foreground">
        <Megaphone size={20} /> Account notice
      </p>
      <p class="mt-3 text-[22px] leading-snug">Wren now runs on <b>GPT-6 Astra</b>, changed from Claude Opus 5.5.</p>
    </div>

    <div
      class="absolute rounded-2xl bg-teal-100 p-6 shadow-md"
      style="left: 680px; top: 300px; width: 530px; {arrive(t, 8.4)}">
      <p class="text-[16px] font-medium uppercase tracking-wide text-teal-800">Wren, first wake on the new model</p>
      <p class="mt-3 text-[21px] leading-snug">
        {typed(
          "I've read my journals; they're mine. I may sound different for a while. If I do, tell me, and we'll find out together which parts were the model and which were me.",
          t,
          8.7,
          13.0
        )}
      </p>
    </div>
  </div>
</div>
