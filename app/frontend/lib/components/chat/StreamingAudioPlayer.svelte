<script>
  import { onDestroy } from 'svelte';
  import { Play, Pause } from 'phosphor-svelte';

  // Listen while Phonon is still making the speech (YNwVle): the same look as
  // AudioPlayer, driven by a stream player (lib/stream-player.js). The bar
  // measures what has been made so far, so it settles once everything is
  // made; seeking works from then on. When the stream has been heard to the
  // end, Listen swaps this for AudioPlayer with the kept WAV.
  let { stream } = $props();

  let view = $state({ playing: false, position: 0, duration: 0, done: false, ended: false });
  const unsubscribe = stream.state.subscribe((value) => (view = value));
  // Web Audio has no timeupdate: read the clock four times a second.
  const timer = setInterval(() => stream.tick(), 250);
  onDestroy(() => {
    unsubscribe();
    clearInterval(timer);
  });

  let progress = $derived(view.duration > 0 ? Math.min(100, (view.position / view.duration) * 100) : 0);

  function toggle() {
    if (view.playing) stream.pause();
    else stream.play();
  }

  function seek(e) {
    if (!view.done || !view.duration) return;
    const rect = e.currentTarget.getBoundingClientRect();
    stream.seek(((e.clientX - rect.left) / rect.width) * view.duration);
  }

  function formatTime(seconds) {
    if (!seconds || !isFinite(seconds)) return '0:00';
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, '0')}`;
  }
</script>

<div class="inline-flex items-center gap-2" data-testid="listen-streaming">
  <button
    type="button"
    onclick={toggle}
    class="inline-flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground transition-colors"
    title={view.playing ? 'Pause' : 'Play voice message'}>
    {#if view.playing}
      <Pause size={14} weight="fill" />
    {:else}
      <Play size={14} weight="fill" />
    {/if}
  </button>

  <button
    type="button"
    onclick={seek}
    disabled={!view.done}
    title={view.done ? undefined : 'Still being made'}
    class="flex-1 h-1 bg-muted rounded-full relative group min-w-[100px] {view.done
      ? 'cursor-pointer'
      : 'cursor-default'}">
    <div class="h-full bg-blue-500 rounded-full" style="width: {progress}%"></div>
    <div
      class="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 w-2.5 h-2.5 bg-blue-500 rounded-full
             opacity-50 group-hover:opacity-100 transition-opacity"
      style="left: {progress}%">
    </div>
  </button>

  <span class="text-[10px] text-muted-foreground tabular-nums w-8 text-right">
    {formatTime(view.position)}
  </span>
</div>
