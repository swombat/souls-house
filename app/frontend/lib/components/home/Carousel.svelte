<script>
  import { CaretLeft, CaretRight } from 'phosphor-svelte';

  // A swipeable row of slides. Native scroll-snap does the swiping (touch, trackpad, shift-wheel);
  // the buttons and the optional autoplay scroll the track one slide at a time.
  // `endHref`: when set, pressing next on the last slide goes there instead of wrapping.
  let {
    items = [],
    slide,
    label,
    autoplayMs = 0,
    endHref = null,
    endLabel = 'See more',
    slideClass = 'w-[85%] sm:w-[60%] lg:w-[40%]',
    testid = 'carousel',
  } = $props();

  let track = $state();
  let current = $state(0);
  let paused = $state(false);
  const reduceMotion =
    typeof window !== 'undefined' && (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false);

  const slides = () => (track ? Array.from(track.children) : []);
  const offsetOf = (el) => el.offsetLeft - track.offsetLeft;
  const atEnd = () => !!track && track.scrollLeft + track.clientWidth >= track.scrollWidth - 8;
  const onLast = () => atEnd() || current >= items.length - 1;

  function scrollToIndex(index) {
    const target = slides()[index];
    if (!target) return;
    track.scrollTo({ left: offsetOf(target), behavior: reduceMotion ? 'auto' : 'smooth' });
  }

  function next() {
    if (!onLast()) return scrollToIndex(current + 1);
    if (endHref) window.location.href = endHref;
    else scrollToIndex(0);
  }

  function prev() {
    scrollToIndex(Math.max(0, current - 1));
  }

  function onScroll() {
    const list = slides();
    if (!list.length) return;
    const distance = (el) => Math.abs(offsetOf(el) - track.scrollLeft);
    let best = 0;
    list.forEach((el, i) => {
      if (distance(el) < distance(list[best])) best = i;
    });
    current = atEnd() ? list.length - 1 : best;
  }

  // Autoplay moves right on a timer and wraps to the start. It holds while the visitor is
  // hovering, focused inside or touching, and never runs with reduced motion.
  $effect(() => {
    if (!autoplayMs || reduceMotion || paused) return;
    const timer = setInterval(() => {
      if (document.hidden) return;
      scrollToIndex(onLast() ? 0 : current + 1);
    }, autoplayMs);
    return () => clearInterval(timer);
  });
</script>

<div
  class="relative"
  role="region"
  aria-roledescription="carousel"
  aria-label={label}
  data-testid={testid}
  onmouseenter={() => (paused = true)}
  onmouseleave={() => (paused = false)}
  onfocusin={() => (paused = true)}
  onfocusout={() => (paused = false)}
  ontouchstart={() => (paused = true)}>
  <ul
    bind:this={track}
    onscroll={onScroll}
    class="flex snap-x snap-mandatory gap-4 overflow-x-auto pb-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
    {#each items as item, index (item.key ?? index)}
      <li
        class="shrink-0 snap-start {slideClass}"
        aria-roledescription="slide"
        aria-label={`${index + 1} of ${items.length}`}
        data-testid="{testid}-slide">
        {@render slide(item, index)}
      </li>
    {/each}
  </ul>
  <div class="mt-4 flex items-center justify-between gap-4">
    <p class="text-sm text-muted-foreground tabular-nums" aria-live="polite">{current + 1} / {items.length}</p>
    <div class="flex gap-2">
      <button
        type="button"
        onclick={prev}
        disabled={current === 0}
        class="inline-flex size-10 items-center justify-center rounded-full border bg-background transition hover:bg-muted disabled:opacity-40"
        aria-label="Previous"
        data-testid="{testid}-prev">
        <CaretLeft size={18} />
      </button>
      <button
        type="button"
        onclick={next}
        class="inline-flex size-10 items-center justify-center rounded-full border bg-background transition hover:bg-muted"
        aria-label={endHref && current >= items.length - 1 ? endLabel : 'Next'}
        data-testid="{testid}-next">
        <CaretRight size={18} />
      </button>
    </div>
  </div>
</div>
