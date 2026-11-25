<script>
  // A feature's changelog clip behind a "Watch example" disclosure, so the
  // Features tab stays a list of switches rather than a wall of video.
  // The video only loads once the disclosure is opened.
  let { name, label } = $props();
  let open = $state(false);
</script>

<details class="group text-sm" bind:open data-testid={`feature-clip-${name}`}>
  <summary class="cursor-pointer select-none text-muted-foreground hover:text-foreground">Watch example</summary>
  {#if open}
    <!-- svelte-ignore a11y_media_has_caption -->
    <video
      class="mt-3 w-full max-w-xl rounded-lg border"
      src={`/changelog-clips/${name}.mp4`}
      poster={`/changelog-clips/${name}.jpg`}
      aria-label={label}
      controls
      playsinline
      muted
      autoplay
      loop
      preload="metadata"></video>
  {/if}
</details>
