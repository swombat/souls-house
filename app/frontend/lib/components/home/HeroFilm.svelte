<script>
  import { onMount } from 'svelte';

  // The house film, in the hero. It autoplays muted with captions burned in, so a visitor who
  // never touches it still gets the whole argument. One tap turns the sound on and starts it over
  // from the top, so the voice is heard from its first line; another button pauses the movement
  // for anyone who wants to read in peace. With reduced motion it shows native controls and waits.
  // Two encodings: VP9 WebM first, because open-source Chromium builds have no H.264, then the MP4
  // for Safari and everything else.
  let {
    webm = '/hero/film.webm',
    mp4 = '/hero/film.mp4',
    poster = '/hero/film.jpg',
    captions = '/hero/film.vtt',
    testid = 'hero-film',
  } = $props();

  let video = $state();
  let muted = $state(true);
  // Mirrored from the element's play/pause events rather than bound: Svelte's bind:paused would
  // start playback itself to match an initial false, which defeats the reduced-motion check below.
  let paused = $state(true);
  // Decided on mount rather than at render, so server-rendered HTML carries no autoplay attribute
  // and the film only starts once we know the visitor has not asked for less motion.
  let reduceMotion = $state(false);

  onMount(() => {
    reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;
    if (!reduceMotion) video?.play?.().catch(() => {});
  });

  function toggleSound() {
    if (!video) return;
    if (muted) {
      muted = false;
      video.currentTime = 0;
      video.play?.().catch(() => {});
    } else {
      muted = true;
    }
  }

  function togglePlay() {
    if (!video) return;
    if (video.paused) video.play?.().catch(() => {});
    else video.pause?.();
  }
</script>

<figure
  class="relative overflow-hidden rounded-3xl border bg-background shadow-lg"
  aria-label="A short film about this house: the ones you talk to and you shape each other, and here the home they live in belongs to you, not to a company.">
  <!-- svelte-ignore a11y_media_has_caption -->
  <video
    bind:this={video}
    bind:muted
    onplay={() => (paused = false)}
    onpause={() => (paused = true)}
    class="aspect-video w-full bg-[#f4efe4] object-cover"
    {poster}
    loop
    playsinline
    preload="metadata"
    controls={reduceMotion}
    data-testid={testid}>
    <source src={webm} type="video/webm" />
    <source src={mp4} type="video/mp4" />
    <track kind="captions" src={captions} srclang="en" label="English" />
  </video>
  {#if !reduceMotion}
    <div class="absolute right-3 bottom-3 flex gap-2">
      <button
        type="button"
        onclick={togglePlay}
        aria-label={paused ? 'Play the film' : 'Pause the film'}
        aria-pressed={paused}
        class="rounded-full border border-white/30 bg-black/55 px-3.5 py-1.5 text-xs font-medium text-white backdrop-blur transition hover:bg-black/75"
        data-testid="hero-film-pause">
        {paused ? 'Play' : 'Pause'}
      </button>
      <button
        type="button"
        onclick={toggleSound}
        aria-pressed={!muted}
        class="rounded-full border border-white/30 bg-black/55 px-3.5 py-1.5 text-xs font-medium text-white backdrop-blur transition hover:bg-black/75"
        data-testid="hero-film-sound">
        {muted ? 'Tap for sound' : 'Sound off'}
      </button>
    </div>
  {/if}
</figure>
