<script>
  import { onDestroy, onMount } from 'svelte';
  import { Microphone, MicrophoneSlash, Spinner, Stop } from 'phosphor-svelte';
  import { captureSupported, startCapture } from '$lib/voice-mode-capture';
  import { stripReleasePhrase } from '$lib/voice-mode';
  import { holdForRecording } from '$lib/recording-guard';
  import { micErrorMessage } from '$lib/mic-recorder';
  import { readTranscription, transcriptionRequest } from '$lib/voice-note-recovery';
  import { accountChatMessagesPath } from '@/routes';
  import * as logging from '$lib/logging';

  // A conversation in voice mode (VoiceMode, YMaddY). Listening starts at
  // once; each utterance the detector closes is transcribed through the same
  // path a voice note takes, then sent as an ordinary human message flagged
  // voice_mode, with the recording attached as voice notes are. The person
  // never presses anything until End.
  let { accountId, chatId, userId, onsent, onerror, onend } = $props();

  // starting | listening | hearing | transcribing | sending | muted | failed
  let phase = $state('starting');
  let level = $state(0);
  let threshold = $state(0.012);
  let heard = $state('');
  let note = $state('');
  let sent = $state(0);
  let stale = $state(false);

  let capture = null;
  let releaseHold = null;
  let queue = Promise.resolve();
  let ended = false;
  let lastSampleAt = 0;
  let watchdog = null;

  const busy = $derived(phase === 'transcribing' || phase === 'sending');
  const status = $derived.by(() => {
    if (phase === 'starting') return 'Opening the microphone…';
    if (phase === 'failed') return note || 'Voice mode could not start.';
    if (phase === 'muted') return 'Muted. Nothing you say is sent.';
    if (phase === 'transcribing') return 'Transcribing…';
    if (phase === 'sending') return 'Sending…';
    if (phase === 'hearing') return 'Hearing you…';
    return 'Listening. Speak, and pause when you are done.';
  });

  const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || '';

  onMount(async () => {
    if (!captureSupported()) {
      phase = 'failed';
      note = 'This browser cannot capture audio for voice mode.';
      return;
    }
    // Held for the whole conversation: a deploy mid-walk must not reload the
    // page and close the microphone; leaving the page asks first.
    releaseHold = holdForRecording();
    try {
      capture = await startCapture({
        onlevel: (rms, limit) => {
          level = rms;
          threshold = limit;
          lastSampleAt = performance.now();
          stale = false;
        },
        onspeechstart: () => {
          if (phase === 'listening') phase = 'hearing';
        },
        ondiscard: () => {
          if (phase === 'hearing') phase = 'listening';
        },
        onturn: (blob, durationMs) => enqueue(blob, durationMs),
      });
      if (ended) {
        await capture.stop();
        return;
      }
      phase = 'listening';
      lastSampleAt = performance.now();
      // Samples stop when the browser suspends the page (a locked phone, a
      // backgrounded tab). Say so rather than show a listening screen that isn't.
      watchdog = setInterval(() => {
        if (phase === 'muted' || phase === 'failed' || phase === 'starting') return;
        stale = performance.now() - lastSampleAt > 3000;
      }, 1000);
    } catch (error) {
      phase = 'failed';
      note = micErrorMessage(error);
      onerror?.(note);
      releaseHold?.();
      releaseHold = null;
    }
  });

  onDestroy(() => {
    ended = true;
    clearInterval(watchdog);
    capture?.stop();
    releaseHold?.();
  });

  // Turns are handled one at a time, in the order they were spoken.
  function enqueue(blob, durationMs) {
    queue = queue.then(() => handleTurn(blob, durationMs)).catch((error) => logging.error('voice turn failed', error));
  }

  async function handleTurn(blob, durationMs) {
    if (ended) return;
    phase = 'transcribing';
    note = '';
    const form = new FormData();
    form.append('audio', blob, 'turn.wav');
    const result = await readTranscription(await transcriptionRequest({ accountId, chatId }, 'POST', form));
    if (ended) return;
    if (!result.ok) {
      note = result.error || 'Transcription failed.';
      phase = capture?.muted ? 'muted' : 'listening';
      return;
    }
    const { text } = stripReleasePhrase(result.text);
    if (!text) {
      note = `Heard ${Math.round(durationMs / 1000)}s of sound but no words.`;
      phase = capture?.muted ? 'muted' : 'listening';
      return;
    }
    await send(text, result.signedId);
  }

  async function send(text, signedId) {
    phase = 'sending';
    const form = new FormData();
    form.append('message[content]', text);
    form.append('voice_mode', '1');
    if (signedId) form.append('audio_signed_id', signedId);
    let response;
    try {
      response = await fetch(accountChatMessagesPath(accountId, chatId), {
        method: 'POST',
        headers: { Accept: 'application/json', 'X-CSRF-Token': csrf(), 'X-Draft-User': userId },
        credentials: 'same-origin',
        body: form,
      });
    } catch {
      response = null;
    }
    if (ended) return;
    const data = response ? await response.json().catch(() => ({})) : {};
    if (!response?.ok) {
      const errors = data?.errors;
      note = Array.isArray(errors) ? errors.join(', ') : errors || 'Could not send what you said.';
      // 403: the mode was switched off (or lost its key) under us. Stop listening.
      if (response?.status === 403) {
        onerror?.(note);
        await end();
        return;
      }
      phase = capture?.muted ? 'muted' : 'listening';
      return;
    }
    heard = text;
    sent += 1;
    onsent?.(data);
    phase = capture?.muted ? 'muted' : 'listening';
  }

  function toggleMute() {
    if (!capture || busy) return;
    const on = !capture.muted;
    capture.mute(on);
    phase = on ? 'muted' : 'listening';
  }

  async function end() {
    if (ended) return;
    ended = true;
    clearInterval(watchdog);
    const open = capture;
    capture = null;
    await open?.stop();
    releaseHold?.();
    releaseHold = null;
    onend?.({ sent });
  }

  const meter = $derived(Math.min(100, Math.round((level / Math.max(threshold * 4, 0.001)) * 100)));
</script>

<div class="space-y-3" data-testid="voice-mode-panel" aria-live="polite">
  <div class="flex items-center gap-3">
    <div
      class="relative h-10 w-10 shrink-0 rounded-full flex items-center justify-center
             {phase === 'hearing' ? 'bg-primary text-primary-foreground' : 'bg-muted text-muted-foreground'}">
      {#if phase === 'starting' || busy}
        <Spinner size={18} class="animate-spin" />
      {:else if phase === 'muted'}
        <MicrophoneSlash size={18} />
      {:else}
        <Microphone size={18} />
      {/if}
    </div>
    <div class="min-w-0 flex-1">
      <p class="text-sm" data-testid="voice-mode-status">{status}</p>
      <div class="mt-1 h-1.5 w-full rounded bg-muted overflow-hidden" aria-hidden="true">
        <div class="h-full bg-primary transition-[width] duration-100" style:width="{phase === 'muted' ? 0 : meter}%">
        </div>
      </div>
    </div>
    <button
      type="button"
      onclick={toggleMute}
      disabled={phase === 'starting' || phase === 'failed' || busy}
      aria-pressed={phase === 'muted'}
      aria-label={phase === 'muted' ? 'Unmute' : 'Mute'}
      class="h-10 w-10 inline-flex items-center justify-center rounded-md hover:bg-accent disabled:opacity-50">
      {#if phase === 'muted'}<Microphone size={18} />{:else}<MicrophoneSlash size={18} />{/if}
    </button>
    <button
      type="button"
      onclick={end}
      aria-label="End voice mode"
      class="h-10 px-3 inline-flex items-center gap-2 rounded-md bg-destructive text-destructive-foreground hover:bg-destructive/90">
      <Stop size={16} weight="fill" /> End
    </button>
  </div>
  {#if stale}
    <p class="text-xs text-amber-700 dark:text-amber-400" data-testid="voice-mode-stale">
      No sound is reaching the page. If the screen locked or the tab went to the background, the browser may have paused
      the microphone; bring the page back to the front.
    </p>
  {/if}
  {#if note}
    <p class="text-xs text-muted-foreground" data-testid="voice-mode-note">{note}</p>
  {/if}
  {#if heard}
    <p class="text-xs text-muted-foreground truncate" data-testid="voice-mode-heard">Sent: “{heard}”</p>
  {/if}
</div>
