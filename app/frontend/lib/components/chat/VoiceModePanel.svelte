<script>
  import { Microphone, MicrophoneSlash, Spinner, Stop } from 'phosphor-svelte';
  import { createVoiceModeSession } from '$lib/voice-mode-session.svelte.js';
  import VoiceModeReadout from './VoiceModeReadout.svelte';
  import VoiceModeHeld from './VoiceModeHeld.svelte';

  // A conversation in voice mode (VoiceMode, YMaddY): the live caption, the
  // replies read aloud, held turns with Retry and Discard, and the pause when
  // the browser stops the microphone. The logic is in voice-mode-session.svelte.js.
  // Props: accountId, chatId, userId, messages, onsent, onerror, onend, and
  // endDrainMs (how long End waits for turns in flight; tests shorten it).
  const props = $props();
  const session = createVoiceModeSession(props);
</script>

<div class="space-y-3" data-testid="voice-mode-panel" aria-live="polite">
  <div class="flex items-center gap-3">
    <div
      class="relative h-10 w-10 shrink-0 rounded-full flex items-center justify-center
             {session.phase === 'hearing' ? 'bg-primary text-primary-foreground' : 'bg-muted text-muted-foreground'}">
      {#if session.phase === 'starting' || session.busy}
        <Spinner size={18} class="animate-spin" />
      {:else if session.muted}
        <MicrophoneSlash size={18} />
      {:else}
        <Microphone size={18} />
      {/if}
    </div>
    <div class="min-w-0 flex-1">
      <p class="text-sm" data-testid="voice-mode-status">{session.status}</p>
      <div class="mt-1 h-1.5 w-full rounded bg-muted overflow-hidden" aria-hidden="true">
        <div
          class="h-full bg-primary transition-[width] duration-100"
          style:width="{session.muted ? 0 : session.meter}%">
        </div>
      </div>
    </div>
    <button
      type="button"
      onclick={session.toggleMute}
      disabled={session.phase === 'starting' || session.phase === 'failed'}
      aria-pressed={session.muted}
      aria-label={session.muted ? 'Unmute' : 'Mute'}
      class="h-10 w-10 inline-flex items-center justify-center rounded-md hover:bg-accent disabled:opacity-50">
      {#if session.muted}<Microphone size={18} />{:else}<MicrophoneSlash size={18} />{/if}
    </button>
    <button
      type="button"
      onclick={() => session.end()}
      aria-label="End voice mode"
      class="h-10 px-3 inline-flex items-center gap-2 rounded-md bg-destructive text-destructive-foreground hover:bg-destructive/90">
      <Stop size={16} weight="fill" /> End
    </button>
  </div>
  <VoiceModeReadout
    stale={session.stale && !session.paused}
    note={session.note}
    speaking={session.speaking}
    caption={session.caption}
    provisional={session.provisional}
    heard={session.heard} />
  <VoiceModeHeld held={session.held} onretry={session.retryFront} ondiscard={session.discardHeld} />
</div>
