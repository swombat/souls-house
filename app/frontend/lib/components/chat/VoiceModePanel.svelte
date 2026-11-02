<script>
  import { onDestroy, onMount } from 'svelte';
  import { Microphone, MicrophoneSlash, Spinner, Stop } from 'phosphor-svelte';
  import { captureSupported, startCapture } from '$lib/voice-mode-capture';
  import { stripReleasePhrase } from '$lib/voice-mode';
  import { createTranscriber } from '$lib/voice-mode-realtime';
  import { holdForRecording } from '$lib/recording-guard';
  import { micErrorMessage } from '$lib/mic-recorder';
  import { postVoiceMessage, requestVoiceSession } from '$lib/voice-mode-api';
  import { createPlayer } from '$lib/voice-mode-playback';
  import { createReplyPicker } from '$lib/voice-mode-replies';
  import { messageSpeechPath } from '@/routes';
  import * as logging from '$lib/logging';

  // A conversation in voice mode (VoiceMode, YMaddY). Listening starts at
  // once. While the person speaks, the audio streams to OpenAI's realtime
  // transcriber and the words appear as a caption; when the detector closes
  // the turn it is committed, and the final text is sent as an ordinary human
  // message flagged voice_mode. No recording is kept. Resident replies that
  // arrive meanwhile are read aloud in their voices; speaking interrupts them.
  let { accountId, chatId, userId, messages = [], onsent, onerror, onend } = $props();

  // starting | listening | hearing | transcribing | sending | failed. Mute is
  // separate: it stops what the microphone sends, whatever the earlier turns
  // are still doing.
  let phase = $state('starting');
  let muted = $state(false);
  let level = $state(0);
  let threshold = $state(0.012);
  let heard = $state('');
  let caption = $state('');
  let note = $state('');
  let sent = $state(0);
  let stale = $state(false);
  let speakingId = $state(null);

  const picker = createReplyPicker(messages);
  const player = createPlayer({ urlFor: (id) => messageSpeechPath(id), onchange: (id) => (speakingId = id) });
  // The player is terminal once End begins, so nothing lands during its drain.
  $effect(() => picker.take(messages).forEach((id) => player.enqueue(id)));

  let capture = null;
  let transcriber = null;
  let releaseHold = null;
  let queue = Promise.resolve();
  let ended = false;
  let lastSampleAt = 0;
  let watchdog = null;

  const busy = $derived(phase === 'transcribing' || phase === 'sending');
  const status = $derived.by(() => {
    if (phase === 'starting') return 'Opening the microphone…';
    if (phase === 'failed') return note || 'Voice mode could not start.';
    const hush = muted ? ' Muted: nothing new is sent.' : '';
    if (phase === 'transcribing') return `Transcribing…${hush}`;
    if (phase === 'sending') return `Sending…${hush}`;
    if (muted) return 'Muted. Nothing you say is sent.';
    if (phase === 'hearing') return 'Hearing you…';
    if (speakingId) return 'Speaking. Talk to interrupt.';
    return 'Listening. Speak, and pause when you are done.';
  });

  const END_DRAIN_MS = 6000;
  const SEND_TIMEOUT_MS = 20_000;

  onMount(async () => {
    if (!captureSupported()) {
      phase = 'failed';
      note = 'This browser cannot capture audio for voice mode.';
      return;
    }
    // Held for the whole conversation: a deploy mid-walk must not reload the
    // page and close the microphone; leaving the page asks first.
    releaseHold = holdForRecording();
    transcriber = createTranscriber({
      fetchSession,
      onDelta: (text) => (caption = text),
      onError: (message) => logging.error('voice transcriber error', message),
    });
    // Connect now so the first turn doesn't wait for the handshake; a failure
    // here is reported by the first turn that needs the connection.
    transcriber.connect().catch((error) => (note = error.message));
    try {
      capture = await startCapture({
        onlevel: (rms, limit) => {
          level = rms;
          threshold = limit;
          lastSampleAt = performance.now();
          stale = false;
        },
        onspeechstart: (samples) => {
          picker.hold(messages);
          player.interrupt();
          caption = '';
          transcriber?.begin(samples);
          if (phase === 'listening') phase = 'hearing';
        },
        onaudio: (samples) => transcriber?.append(samples),
        ondiscard: () => {
          picker.release();
          transcriber?.discard();
          caption = '';
          if (phase === 'hearing') phase = 'listening';
        },
        onturn: (durationMs) => {
          picker.release();
          enqueue(transcriber.commit(), durationMs);
        },
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
        if (muted || phase === 'failed' || phase === 'starting') return;
        stale = performance.now() - lastSampleAt > 3000;
      }, 1000);
    } catch (error) {
      phase = 'failed';
      note = micErrorMessage(error);
      onerror?.(note);
      transcriber?.close();
      releaseHold?.();
      releaseHold = null;
    }
  });

  onDestroy(() => {
    ended = true;
    player.close();
    clearInterval(watchdog);
    capture?.stop();
    transcriber?.close();
    releaseHold?.();
  });

  // A fresh short-lived secret for each (re)connection.
  async function fetchSession() {
    const { ok, status, data } = await requestVoiceSession(accountId, chatId);
    if (!ok) {
      const message = data?.error || 'Transcription could not start.';
      if (status === 403) {
        onerror?.(message);
        end({ drain: false });
      }
      throw new Error(message);
    }
    return data;
  }

  // Turns are sent one at a time, in the order they were spoken; each
  // transcript is already on its way when the next turn starts.
  function enqueue(transcript, durationMs) {
    if (phase === 'hearing') phase = 'transcribing';
    queue = queue
      .then(() => handleTurn(transcript, durationMs))
      .catch((error) => logging.error('voice turn failed', error));
  }

  async function handleTurn(transcript, durationMs) {
    if (ended) return;
    phase = 'transcribing';
    note = '';
    let raw;
    try {
      raw = await transcript;
    } catch (error) {
      if (ended) return;
      note = error?.message || 'Transcription failed.';
      caption = '';
      phase = 'listening';
      return;
    }
    if (ended) return;
    caption = '';
    const { text } = stripReleasePhrase(raw);
    if (!text) {
      note = `Heard ${Math.round(durationMs / 1000)}s of sound but no words.`;
      phase = 'listening';
      return;
    }
    await send(text);
  }

  async function send(text) {
    phase = 'sending';
    const { ok, status, data } = await postVoiceMessage({
      accountId,
      chatId,
      userId,
      text,
      timeoutMs: SEND_TIMEOUT_MS,
    });
    if (ended) return;
    if (!ok) {
      const errors = data?.errors;
      note = Array.isArray(errors) ? errors.join(', ') : errors || 'Could not send what you said.';
      // 403: the mode was switched off (or lost its key) under us. Stop listening.
      if (status === 403) {
        onerror?.(note);
        await end({ drain: false });
        return;
      }
      phase = 'listening';
      return;
    }
    heard = text;
    sent += 1;
    onsent?.(data);
    phase = 'listening';
  }

  // Always available once listening: muting closes any sentence in progress
  // (it is still sent) and feeds silence from then on, while earlier turns
  // finish transcribing and sending in the background.
  function toggleMute() {
    if (!capture) return;
    muted = !muted;
    capture.mute(muted);
  }

  // End sends what was being said when it was pressed (stopping the capture
  // closes the open turn), waiting a few seconds for its transcript at most.
  let ending = false;
  async function end({ drain = true } = {}) {
    if (ended || ending) return;
    ending = true;
    player.close();
    clearInterval(watchdog);
    const open = capture;
    capture = null;
    await open?.stop();
    if (drain) await Promise.race([queue, new Promise((resolve) => setTimeout(resolve, END_DRAIN_MS))]);
    ended = true;
    transcriber?.close();
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
      {:else if muted}
        <MicrophoneSlash size={18} />
      {:else}
        <Microphone size={18} />
      {/if}
    </div>
    <div class="min-w-0 flex-1">
      <p class="text-sm" data-testid="voice-mode-status">{status}</p>
      <div class="mt-1 h-1.5 w-full rounded bg-muted overflow-hidden" aria-hidden="true">
        <div class="h-full bg-primary transition-[width] duration-100" style:width="{muted ? 0 : meter}%"></div>
      </div>
    </div>
    <button
      type="button"
      onclick={toggleMute}
      disabled={phase === 'starting' || phase === 'failed'}
      aria-pressed={muted}
      aria-label={muted ? 'Unmute' : 'Mute'}
      class="h-10 w-10 inline-flex items-center justify-center rounded-md hover:bg-accent disabled:opacity-50">
      {#if muted}<Microphone size={18} />{:else}<MicrophoneSlash size={18} />{/if}
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
  {#if caption}
    <p class="text-sm" data-testid="voice-mode-caption">{caption}</p>
  {/if}
  {#if heard}
    <p class="text-xs text-muted-foreground truncate" data-testid="voice-mode-heard">Sent: “{heard}”</p>
  {/if}
</div>
