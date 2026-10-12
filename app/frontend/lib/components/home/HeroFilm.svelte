<script>
  // The house film, in the hero. It autoplays muted with captions burned in, so a visitor who
  // never touches it still gets the whole argument. One tap turns the sound on and starts it over
  // from the top, so the voice is heard from its first line. With reduced motion it waits to be played.
  let {
    src = '/hero/souls-house.mp4',
    poster = '/hero/souls-house.jpg',
    captions = '/hero/souls-house.vtt',
    testid = 'hero-film',
  } = $props();

  let video = $state();
  let muted = $state(true);
  const reduceMotion =
    typeof window !== 'undefined' && (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false);

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
</script>

<figure
  class="relative overflow-hidden rounded-3xl border bg-background shadow-lg"
  aria-label="A short film about souls.house: the ones you talk to and you shape each other, and here the home they live in belongs to you, not to a company.">
  <!-- svelte-ignore a11y_media_has_caption -->
  <video
    bind:this={video}
    bind:muted
    class="aspect-video w-full bg-[#f4efe4] object-cover"
    {src}
    {poster}
    autoplay={!reduceMotion}
    loop
    playsinline
    preload="metadata"
    controls={reduceMotion}
    data-testid={testid}>
    <track kind="captions" src={captions} srclang="en" label="English" />
  </video>
  {#if !reduceMotion}
    <button
      type="button"
      onclick={toggleSound}
      aria-pressed={!muted}
      class="absolute right-3 bottom-3 rounded-full border border-white/30 bg-black/55 px-3.5 py-1.5 text-xs font-medium text-white backdrop-blur transition hover:bg-black/75"
      data-testid="hero-film-sound">
      {muted ? 'Tap for sound' : 'Sound off'}
    </button>
  {/if}
</figure>
