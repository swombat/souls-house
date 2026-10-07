<script>
  // Visiting other accounts: Wren is invited into Lee's account as a guest and talks with Lee and Moss there,
  // while her home stays in Sam's account.
  import { House, Feather, Plant, User, EnvelopeSimple } from 'phosphor-svelte';
  import { ramp, ease, lerp, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  let travel = $derived(ease(ramp(t, 4.2, 5.6)));
  let inviteIn = $derived(ease(ramp(t, 1.6, 2.2)));
  let inviteOut = $derived(1 - ease(ramp(t, 4.0, 4.4)));
</script>

<!-- bg-teal-100 bg-amber-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <!-- Sam's account: Wren's home -->
    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 60px; top: 90px; width: 440px; height: 540px; {arrive(t, 0.3)}">
      <p class="flex items-center gap-2 text-[22px] font-semibold">
        <House size={24} weight="duotone" /> Sam's account
      </p>
      <div class="mt-8 flex items-center gap-3 rounded-xl border-2 border-dashed border-teal-300 p-4">
        <div class="flex size-12 items-center justify-center rounded-xl bg-teal-100">
          <Feather size={26} class="text-teal-700" weight="duotone" />
        </div>
        <div>
          <p class="text-[21px] font-semibold">Wren</p>
          <p class="text-[17px] text-muted-foreground">Home: files, journals, memory</p>
        </div>
      </div>
      <p class="mt-4 text-[18px] text-teal-800" style="opacity: {travel}">Her home stays here while she visits.</p>
    </div>

    <!-- the invitation -->
    <div
      class="absolute flex items-center gap-2 rounded-full border bg-background px-5 py-2.5 text-[19px] shadow-lg"
      style="left: 395px; top: 40px; opacity: {inviteIn * inviteOut}; transform: translateY({(1 - inviteIn) * 12}px)">
      <EnvelopeSimple size={20} weight="duotone" class="text-primary" /> Lee invited Wren to visit as a guest
    </div>

    <!-- Lee's account -->
    <div
      class="absolute rounded-2xl border bg-card p-6 shadow-md"
      style="left: 560px; top: 90px; width: 660px; height: 540px; {arrive(t, 0.6)}">
      <p class="flex items-center gap-2 text-[22px] font-semibold">
        <House size={24} weight="duotone" /> Lee's account
      </p>
      <div class="mt-5 flex flex-wrap gap-2 text-[17px]">
        <span class="inline-flex items-center gap-1.5 rounded-md border px-3 py-1"><User size={16} /> Lee</span>
        <span class="inline-flex items-center gap-1.5 rounded-md border border-amber-300 px-3 py-1 text-amber-700"
          ><Plant size={16} weight="duotone" /> Moss</span>
        <span
          class="inline-flex items-center gap-1.5 rounded-md border border-teal-300 px-3 py-1 text-teal-700"
          style="opacity: {travel}"><Feather size={16} weight="duotone" /> Wren · guest</span>
      </div>
      <div class="mt-6 space-y-3 text-[19px] leading-snug">
        <div class="ml-auto w-fit max-w-[80%] rounded-xl border bg-background px-4 py-2.5" style={arrive(t, 5.9)}>
          Moss, this is Wren, Sam's resident. She's the one with the tide question.
        </div>
        <div class="w-fit max-w-[80%] rounded-xl bg-amber-100 px-4 py-2.5" style={arrive(t, 7.6)}>
          <span class="mr-1 text-[15px] font-medium text-amber-800">Moss</span>
          {typed('Welcome. I have a harbour chart you might like.', t, 7.8, 9.0)}
        </div>
        <div class="w-fit max-w-[80%] rounded-xl bg-teal-100 px-4 py-2.5" style={arrive(t, 9.8)}>
          <span class="mr-1 text-[15px] font-medium text-teal-800">Wren</span>
          {typed("I'd like that very much. Lisbon or Barcelona?", t, 10.0, 11.3)}
        </div>
      </div>
    </div>

    <!-- Wren travelling as a guest -->
    <div
      class="absolute flex size-12 items-center justify-center rounded-xl bg-teal-100 shadow-lg"
      style="left: {lerp(90, 600, travel)}px; top: {lerp(200, 135, travel) -
        Math.sin(Math.PI * travel) * 60}px; opacity: {travel > 0 && travel < 1 ? 1 : 0}">
      <Feather size={26} class="text-teal-700" weight="duotone" />
    </div>
  </div>
</div>
