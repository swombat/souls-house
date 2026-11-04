<script>
  import { Waveform } from 'phosphor-svelte';
  import { unlockAudio } from '$lib/voice-mode-playback';

  // Shown in place of Send while the composer is empty and voice mode is
  // offered (VoiceMode.status_for). Not a disabled button when the mode cannot
  // start: a tap then explains why, since titles don't show on phones.
  let { voiceMode, onopen, notice = $bindable('') } = $props();

  const VOICE_REASONS = {
    no_transcription_key:
      "Voice mode needs an OpenAI API key for this account. Add one under the account's model provider keys, or let the account use the house keys.",
  };
  const reason = $derived(VOICE_REASONS[voiceMode?.reason] || 'Voice mode is not available in this account.');

  function open() {
    if (!voiceMode?.available) {
      notice = reason;
      return;
    }
    notice = '';
    unlockAudio(); // inside the tap, or phones refuse to play replies later
    onopen?.();
  }
</script>

<button
  type="button"
  onclick={open}
  aria-label="Start voice mode"
  aria-disabled={!voiceMode?.available}
  title={voiceMode?.available ? 'Talk to this conversation' : reason}
  data-testid="voice-mode-button"
  class="col-start-4 row-start-1 h-10 w-10 p-0 inline-flex items-center justify-center rounded-md
       {voiceMode?.available
    ? 'bg-primary text-primary-foreground hover:bg-primary/90'
    : 'bg-muted text-muted-foreground'}">
  <Waveform size={18} />
</button>
