<script>
  // Bring your own subscription: connect an OpenAI plan to Wren with a device code; the connection lives in
  // her own runtime and her usage draws on that plan.
  import { Copy, Feather, CheckCircle } from 'phosphor-svelte';
  import { ramp, ease, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 15;
  let stage = $derived(t < 2.2 ? 'starting' : t < 8.4 ? 'pending' : 'connected');
  let seconds = $derived(Math.max(0, 900 - Math.floor((t - 2.2) * 9)));
  let phone = $derived(ease(ramp(t, 4.6, 5.2)) * (1 - ease(ramp(t, 8.2, 8.6))));
  let typedCode = $derived('KQ7M-4TZP'.slice(0, Math.round(9 * ramp(t, 5.6, 6.8))));
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute rounded-xl border bg-background p-8 shadow-xl"
      style="left: 120px; top: 70px; width: 640px; {arrive(t, 0.3)}">
      <p class="text-[26px] font-semibold">Connect OpenAI subscription</p>
      <p class="mt-2 text-[18px] text-muted-foreground">
        This connection belongs only to Wren and is stored in its private runtime state volume.
      </p>
      <div class="mt-6 space-y-4 text-[19px]">
        {#if stage === 'starting'}
          <p class="text-muted-foreground">Starting provider sign-in…</p>
        {:else if stage === 'pending'}
          <p class="font-medium text-primary underline underline-offset-4">Open provider sign-in</p>
          <div class="flex items-center gap-3">
            <code class="rounded-md bg-muted px-5 py-2.5 text-[28px] font-semibold tracking-widest">KQ7M-4TZP</code>
            <span class="flex size-11 items-center justify-center rounded-md border"><Copy size={20} /></span>
          </div>
          <p class="text-muted-foreground">
            Code expires in {Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, '0')}.
          </p>
          <div class="rounded-md border border-amber-400/40 bg-amber-50 p-3 text-[17px] text-amber-950">
            Device codes are a common phishing target. Never share this code.
          </div>
          <p class="text-muted-foreground">Waiting for sign-in to finish…</p>
        {:else}
          <div
            class="flex items-start gap-2 rounded-md border border-emerald-500/30 bg-emerald-500/10 p-4"
            style={arrive(t, 8.4, 8)}>
            <CheckCircle size={22} weight="fill" class="mt-0.5 shrink-0 text-emerald-600" />
            <span
              >Connected successfully as sam@example.com. Resident usage now draws on this account's personal plan
              quota.</span>
          </div>
        {/if}
      </div>
    </div>

    <!-- the person's own device, entering the code at the provider -->
    <div
      class="absolute rounded-[28px] border-4 border-slate-800 bg-white p-5 shadow-2xl"
      style="left: 840px; top: 110px; width: 320px; height: 500px; opacity: {phone}; transform: translateY({(1 -
        phone) *
        30}px)">
      <p class="text-center text-[16px] text-muted-foreground">openai.com · device sign-in</p>
      <p class="mt-8 text-center text-[20px] font-semibold">Enter the code shown on your device</p>
      <div
        class="mt-6 rounded-lg border-2 border-slate-300 px-3 py-3 text-center font-mono text-[26px] tracking-widest">
        {typedCode}<span class="text-slate-300">{'KQ7M-4TZP'.slice(typedCode.length).replace(/[A-Z0-9]/g, '_')}</span>
      </div>
      <div
        class="mt-6 rounded-lg bg-slate-900 py-3 text-center text-[18px] text-white"
        style="opacity: {0.4 + 0.6 * ease(ramp(t, 6.9, 7.2))}">
        Continue
      </div>
    </div>

    <div
      class="absolute flex items-center gap-3 rounded-xl bg-teal-100 px-5 py-3 text-[19px] shadow-md"
      style="left: 120px; top: 560px; {arrive(t, 10.4)}">
      <Feather size={22} weight="duotone" class="text-teal-700" /> Wren is running on your plan.
    </div>
  </div>
</div>
