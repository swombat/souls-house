<script>
  import { untrack } from 'svelte';
  import { SpeakerHigh, SpeakerSlash } from 'phosphor-svelte';
  import { createReadAloud } from '$lib/read-aloud';

  // The header's "Read replies aloud" speaker (lib/read-aloud.js): off, on,
  // speaking, paused while voice mode is open, or "Tap to play" when the
  // browser refused to start a reply without a tap.
  let { chatId, messages = [] } = $props();

  let view = $state({ on: false, paused: false, speaking: null, blocked: false, note: '' });
  let control = null;

  // The header passes chat.id, and that prop follows the whole chat object,
  // which every chat reload replaces (one comes with each new reply). Only a
  // real change of conversation may make a new reader: a new reader's boundary
  // is "now", so remaking it on a reload would skip the reply that caused it.
  const id = $derived(chatId);

  $effect(() => {
    const current = id;
    const made = untrack(() =>
      createReadAloud({ chatId: current, messages: () => messages || [], onstate: (next) => (view = next) })
    );
    control = made;
    return () => {
      made.destroy();
      if (control === made) control = null;
    };
  });
  // The picker reads every message, which is what makes this effect follow
  // the list as it changes in place; while off there is no picker, so the
  // effect also follows the state and starts following the list once on.
  $effect(() => {
    void view.on;
    void view.paused;
    control?.take(messages || []);
  });

  const label = $derived(
    !view.on
      ? 'Read replies aloud'
      : view.paused
        ? 'Reading aloud is paused while voice mode is on'
        : view.blocked
          ? 'Tap to play the replies waiting to be read'
          : view.speaking
            ? 'Reading a reply aloud. Tap to stop'
            : 'Reading replies aloud. Tap to stop'
  );
  const status = $derived(
    !view.on ? 'off' : view.paused ? 'paused' : view.blocked ? 'blocked' : view.speaking ? 'speaking' : 'on'
  );
</script>

<button
  type="button"
  data-testid="read-aloud-toggle"
  data-state={status}
  aria-pressed={view.on}
  aria-label={label}
  title={view.note || label}
  onclick={() => control?.toggle()}
  class="inline-flex h-8 min-w-8 items-center justify-center gap-1 rounded-md px-1.5 text-sm transition-colors
         hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2
         focus-visible:ring-ring focus-visible:ring-offset-2
         {view.on ? 'text-primary' : 'text-muted-foreground'} {view.paused ? 'opacity-50' : ''}">
  {#if view.on}
    <SpeakerHigh
      size={20}
      weight={view.speaking ? 'fill' : 'regular'}
      class={view.speaking ? 'motion-safe:animate-pulse' : ''} />
  {:else}
    <SpeakerSlash size={20} />
  {/if}
  {#if view.on && view.blocked && !view.paused}
    <span class="text-xs whitespace-nowrap">Tap to play</span>
  {/if}
</button>
