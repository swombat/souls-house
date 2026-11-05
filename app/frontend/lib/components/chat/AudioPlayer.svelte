<script>
  import { Play, Pause } from 'phosphor-svelte';

  // autoplay: start as soon as the audio is ready (Listen with Phonon, where
  // the tap that asked for it came before the audio was made). A browser that
  // refuses leaves the play button, as without it.
  let { src, autoplay = false } = $props();

  let audioEl = $state(null);
  let playing = $state(false);
  let progress = $state(0);
  let duration = $state(0);
  let currentTime = $state(0);

  function toggle() {
    if (playing) {
      audioEl?.pause();
    } else {
      audioEl?.play();
    }
  }

  function handleTimeUpdate() {
    if (!audioEl) return;
    currentTime = audioEl.currentTime;
    if (duration > 0 && isFinite(duration)) {
      progress = (currentTime / duration) * 100;
    }
  }

  function handleLoadedMetadata() {
    if (!audioEl) return;
    if (isFinite(audioEl.duration)) {
      duration = audioEl.duration;
    } else {
      // WebM files from MediaRecorder often lack duration metadata.
      // Seeking to a huge time forces the browser to calculate the real duration.
      audioEl.currentTime = 1e10;
    }
  }

  function handleDurationChange() {
    if (audioEl && isFinite(audioEl.duration)) {
      duration = audioEl.duration;
    }
  }

  function handleSeeked() {
    // After the duration-discovery seek trick, reset to the beginning
    if (audioEl && audioEl.currentTime >= 1e10) {
      duration = audioEl.duration;
      audioEl.currentTime = 0;
    }
  }

  let autoplayed = false;
  $effect(() => {
    if (!autoplay || autoplayed || !audioEl || !src) return;
    autoplayed = true;
    audioEl.play()?.catch?.(() => {});
  });

  function handleEnded() {
    playing = false;
    progress = 0;
    currentTime = 0;
  }

  function seek(e) {
    if (!audioEl || !duration || !isFinite(duration)) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const ratio = (e.clientX - rect.left) / rect.width;
    audioEl.currentTime = ratio * duration;
  }

  function formatTime(seconds) {
    if (!seconds || !isFinite(seconds)) return '0:00';
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, '0')}`;
  }
</script>

<div class="inline-flex items-center gap-2">
  <button
    type="button"
    onclick={toggle}
    class="inline-flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground transition-colors"
    title={playing ? 'Pause' : 'Play voice message'}>
    {#if playing}
      <Pause size={14} weight="fill" />
    {:else}
      <Play size={14} weight="fill" />
    {/if}
  </button>

  <button
    type="button"
    onclick={seek}
    class="flex-1 h-1 bg-muted rounded-full cursor-pointer relative group min-w-[100px]">
    <div class="h-full bg-blue-500 rounded-full transition-all" style="width: {progress}%"></div>
    <div
      class="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 w-2.5 h-2.5 bg-blue-500 rounded-full
             opacity-50 group-hover:opacity-100 transition-opacity"
      style="left: {progress}%">
    </div>
  </button>

  <span class="text-[10px] text-muted-foreground tabular-nums w-8 text-right">
    {playing ? formatTime(currentTime) : formatTime(duration)}
  </span>

  <audio
    bind:this={audioEl}
    {src}
    preload="metadata"
    onplay={() => (playing = true)}
    onpause={() => (playing = false)}
    ontimeupdate={handleTimeUpdate}
    onloadedmetadata={handleLoadedMetadata}
    ondurationchange={handleDurationChange}
    onseeked={handleSeeked}
    onended={handleEnded}>
  </audio>
</div>
