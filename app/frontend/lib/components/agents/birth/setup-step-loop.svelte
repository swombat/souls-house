<script>
  // The picture for the setup step in progress on a resident's own server; the drawing lives in
  // setup-step-scene.js as a pure function of time, one 6 second loop per step.
  import { onMount } from 'svelte';
  import { W, H, LOOP, SCENES, drawStep } from './setup-step-scene.js';
  import { penFor } from './seed-loop-scene.js';

  let { step, class: className = '' } = $props();

  let canvas = $state(null);
  let current = step;
  let started = 0;

  $effect(() => {
    if (step !== current) {
      current = step;
      started = performance.now();
    }
  });

  onMount(() => {
    if (/jsdom/i.test(navigator.userAgent)) return;
    let ctx = null;
    try {
      ctx = canvas?.getContext?.('2d') ?? null;
    } catch {
      ctx = null;
    }
    if (!ctx) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    ctx.scale(dpr, dpr);
    let pen = penFor(canvas);

    // ?step-t=3 freezes a frame (screenshots); reduced motion gets each step's settled picture.
    const pinned = Number(new URLSearchParams(window.location.search).get('step-t'));
    const still = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    const observer = new MutationObserver(() => (pen = penFor(canvas)));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'style'] });

    let frame;
    started = performance.now();
    const tick = (now) => {
      const T = (now - started) / 1000;
      drawStep(ctx, pen, current, still || pinned ? pinned || 4.5 : T % LOOP, T);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
    };
  });
</script>

{#if SCENES[step]}
  <canvas
    bind:this={canvas}
    width={W}
    height={H}
    class="block h-auto w-full {className}"
    style="aspect-ratio: {W} / {H}"
    aria-hidden="true"
    data-testid="setup-step-loop"
    data-step={step}></canvas>
{/if}
