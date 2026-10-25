<script>
  // The canvas and the animation frame for the seed loop; the drawing itself lives in
  // seed-loop-scene.js as a pure function of time.
  import { onMount } from 'svelte';
  import { W, H, LOOP, drawFrame, penFor } from './seed-loop-scene.js';

  let { class: className = '' } = $props();

  let canvas = $state(null);

  onMount(() => {
    // jsdom (unit tests) has no canvas and says so loudly.
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

    // ?seed-t=8.4 freezes a frame (screenshots); reduced motion gets the dot beside its flower.
    const pinned = Number(new URLSearchParams(window.location.search).get('seed-t'));
    const still = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    if (still || pinned) {
      drawFrame(ctx, pen, pinned || 8.4, pinned || 0);
      return;
    }

    // Light and dark mode swap the card's colours under us; pick them up again when they change.
    const observer = new MutationObserver(() => (pen = penFor(canvas)));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'style'] });

    let frame;
    const start = performance.now();
    const tick = (now) => {
      const T = (now - start) / 1000;
      drawFrame(ctx, pen, T % LOOP, T);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
    };
  });
</script>

<canvas
  bind:this={canvas}
  width={W}
  height={H}
  class="block h-auto w-full {className}"
  style="aspect-ratio: {W} / {H}; mask-image: linear-gradient(to bottom, transparent 0, #000 22%); -webkit-mask-image: linear-gradient(to bottom, transparent 0, #000 22%)"
  aria-hidden="true"
  data-testid="seed-loop"></canvas>
