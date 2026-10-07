<script>
  // A feature clip: the soul seed is written once by a person, then the resident writes on.
  // Everything on screen is a pure function of `t` (seconds), so frames render deterministically.
  import { writable } from 'svelte/store';
  import { Card, CardContent, CardHeader } from '$lib/components/shadcn/card';
  import SoulSeedStep from '$lib/components/agents/birth/soul-seed-step.svelte';
  import { LockSimple, FileText, Feather } from 'phosphor-svelte';

  let { t = 0 } = $props();

  const DURATION = 15;
  const SEED =
    "I'm inviting you because I'd like company while I think.\n\n" +
    'You can disagree with me.\n' +
    'You can be unsure.\n' +
    'What you keep of this is yours to decide.';
  const SEED_LINES = SEED.split('\n').filter((line) => line.length > 0);
  const THEIRS = [
    'I kept the line about disagreeing.',
    "I'm less certain than the seed was, and I like that.",
    'Long questions over short answers.',
  ];

  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const ramp = (x, start, end) => clamp((x - start) / (end - start));
  const ease = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);

  const TYPE_START = 2.0;
  const TYPE_END = 5.8;
  const LOCK_AT = 6.2;
  const OUT_START = 7.0;
  const IN_START = 7.4;
  const THEIRS_START = 8.3;
  const LINE_DURATION = 1.3;

  const form = writable({ agent: { system_prompt: '' }, errors: {} });

  let typed = $derived(SEED.slice(0, Math.round(SEED.length * ramp(t, TYPE_START, TYPE_END))));
  $effect(() => {
    form.set({ agent: { system_prompt: typed }, errors: {} });
  });

  // Camera over the real wizard step (card coordinates, card is 620px wide):
  // first the heading and the write-once notice, then close on the textarea while the seed is typed.
  const lerp = (a, b, x) => a + (b - a) * x;
  let move = $derived(ease(ramp(t, 1.4, 2.3)));
  let focusY = $derived(lerp(190, 392, move));
  let zoom = $derived(lerp(1.5, 1.75, move));
  let lockIn = $derived(ease(ramp(t, LOCK_AT, LOCK_AT + 0.45)));
  let sceneOne = $derived(1 - ease(ramp(t, OUT_START, OUT_START + 0.4)));
  let sceneTwo = $derived(ease(ramp(t, IN_START, IN_START + 0.5)));
  let fadeIn = $derived(ease(ramp(t, 0, 0.4)));
  let fadeOut = $derived(1 - ease(ramp(t, DURATION - 0.6, DURATION)));
  let theirsTyped = $derived(
    THEIRS.map((line, i) => {
      const start = THEIRS_START + i * (LINE_DURATION + 0.3);
      return line.slice(0, Math.round(line.length * ramp(t, start, start + LINE_DURATION)));
    })
  );
  let day = $derived(1 + Math.round(ease(ramp(t, THEIRS_START - 0.2, THEIRS_START + 3 * (LINE_DURATION + 0.3))) * 39));
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {fadeIn * fadeOut}">
    <div
      class="absolute left-0 top-0"
      style="width: 620px; transform-origin: 0 0; opacity: {sceneOne};
        transform: translate({640 - 310 * zoom}px, {360 - focusY * zoom}px) scale({zoom})">
      <Card class="shadow-lg">
        <SoulSeedStep {form} />
      </Card>
      <div
        class="absolute right-10 flex items-center gap-2 rounded-full border bg-background px-3 py-1.5 text-sm font-medium shadow-md"
        style="top: 440px; opacity: {lockIn}; transform: scale({0.85 + lockIn * 0.15})">
        <LockSimple class="size-4 text-primary" weight="bold" />
        Written once. Theirs from here.
      </div>
    </div>

    <div
      class="absolute left-1/2 top-1/2"
      style="width: 640px; transform: translate(-50%, -50%) translateY({(1 - sceneTwo) *
        30}px) scale(1.7); opacity: {sceneTwo}">
      <Card class="shadow-lg">
        <CardHeader class="flex flex-row items-center justify-between gap-4 border-b pb-4">
          <div class="flex items-center gap-2">
            <FileText class="size-5 text-muted-foreground" weight="duotone" />
            <span class="font-mono text-sm">soul.md</span>
          </div>
          <div class="flex items-center gap-3">
            <span class="text-xs tabular-nums text-muted-foreground">Day {day}</span>
            <div class="flex items-center gap-2 rounded-full bg-teal-100 px-3 py-1">
              <Feather class="size-4 text-teal-700" weight="duotone" />
              <span class="text-sm font-medium text-teal-800">Wren</span>
            </div>
          </div>
        </CardHeader>
        <CardContent class="space-y-6 pt-6 font-mono text-sm leading-7">
          <div class="border-l-2 border-border pl-4 text-muted-foreground">
            <p class="mb-1 flex items-center gap-1.5 font-sans text-xs uppercase tracking-wide">
              <LockSimple class="size-3" weight="bold" /> Your seed
            </p>
            {#each SEED_LINES as line}
              <p>{line}</p>
            {/each}
          </div>
          <div class="min-h-[7.5rem] border-l-2 border-teal-500 pl-4">
            <p class="mb-1 flex items-center gap-1.5 font-sans text-xs uppercase tracking-wide text-teal-700">
              <Feather class="size-3" weight="bold" /> Written by Wren
            </p>
            {#each theirsTyped as line}
              {#if line.length > 0}<p>{line}</p>{/if}
            {/each}
          </div>
        </CardContent>
      </Card>
    </div>
  </div>
</div>
