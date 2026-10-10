<script>
  // A muted looping clip that only loads and plays while it is on screen, so a carousel of
  // twenty clips does not download twenty videos at once. With reduced motion it shows the
  // poster and controls and waits for the visitor.
  let { src, poster, alt, testid = null } = $props();

  let video = $state();
  const reduceMotion =
    typeof window !== 'undefined' && (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false);

  $effect(() => {
    if (!video || reduceMotion || typeof IntersectionObserver === 'undefined') return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) video.play?.().catch(() => {});
        else video.pause?.();
      },
      { threshold: 0.6 }
    );
    observer.observe(video);
    return () => observer.disconnect();
  });
</script>

<video
  bind:this={video}
  class="aspect-video w-full bg-muted object-cover"
  {src}
  {poster}
  aria-label={alt}
  controls={reduceMotion}
  preload="none"
  muted
  loop
  playsinline
  data-testid={testid}></video>
