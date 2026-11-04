<script>
  import { onDestroy, onMount } from 'svelte';
  import { Microphone, MicrophoneSlash, Spinner, Stop } from 'phosphor-svelte';
  import { captureSupported, startCapture } from '$lib/voice-mode-capture';
  import { stripReleasePhrase, voiceModeStatus } from '$lib/voice-mode';
  import { createTranscriber } from '$lib/voice-mode-realtime';
  import { holdForRecording } from '$lib/recording-guard';
  import { micErrorMessage } from '$lib/mic-recorder';
  import { postVoiceMessage, requestVoiceSession } from '$lib/voice-mode-api';
  import { createReplyReader } from '$lib/voice-mode-reader';
  import { createTurnRecorder, transcribeTurn, turnContent } from '$lib/voice-mode-turn-audio';
  import * as logging from '$lib/logging';

  // A conversation in voice mode (VoiceMode, YMaddY). Listening starts at
  // once. While the person speaks, the audio streams to OpenAI's realtime
  // transcriber and the words appear as a caption, and the turn's audio is kept.
  // When the detector closes the turn, the recording is transcribed the way a
  // voice note is (ElevenLabs with the glossary, #756) while the live caption
  // stays up, grey and pulsing, as a sign something was heard; the message is
  // sent with ElevenLabs' text and the recording attached. If that fails, the
  // live text is sent, marked rough. Resident replies that arrive meanwhile are
  // read aloud in their voices; speaking interrupts them.
  let { accountId, chatId, userId, messages = [], onsent, onerror, onend } = $props();

  // starting | listening | hearing | transcribing | sending | failed; mute is separate.
  let phase = $state('starting');
  let muted = $state(false);
  let level = $state(0);
  let threshold = $state(0.012);
  let heard = $state('');
  let caption = $state('');
  // The live text of a finished turn while its clean transcript is on its way.
  let provisional = $state('');
  let note = $state('');
  let sent = $state(0);
  let stale = $state(false);
  let speakingId = $state(null);
  // The reply being read, shown as text too: on a phone the panel is the only
  // evidence that a reply exists while the person is talking.
  const speaking = $derived(speakingId ? messages.find((m) => m.id === speakingId) : null);

  const reader = createReplyReader({ messages, onchange: (id) => (speakingId = id) });
  $effect(() => reader.take(messages));

  let capture = null;
  let transcriber = null;
  const TURN_RATE = 24_000;
  const recorder = createTurnRecorder({ sampleRate: TURN_RATE });
  let releaseHold = null;
  let queue = Promise.resolve();
  let ended = false;
  let lastSampleAt = 0;
  let watchdog = null;

  const busy = $derived(phase === 'transcribing' || phase === 'sending');
  const status = $derived(voiceModeStatus({ phase, muted, note, speaking: speakingId }));

  const END_DRAIN_MS = 6000;
  const SEND_TIMEOUT_MS = 20_000;
  // Above transcribeTurn's own 30 s bound; only reached by an unbounded promise.
  const CLEAN_BACKSTOP_MS = 35_000;

  onMount(async () => {
    if (!captureSupported()) {
      phase = 'failed';
      note = 'This browser cannot capture audio for voice mode.';
      return;
    }
    // Held for the whole conversation: a deploy mid-walk must not reload the
    // page and close the microphone; leaving the page asks first. A live hold,
    // because replies must keep reaching the page while the microphone is open
    // (#748: an ordinary hold cancelled every message reload until End).
    releaseHold = holdForRecording({
      refreshes: false,
      onconflict: () => (note = 'The house was just updated. New replies will appear when you end voice mode.'),
    });
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
        outputRate: TURN_RATE,
        onlevel: (rms, limit) => {
          level = rms;
          threshold = limit;
          lastSampleAt = performance.now();
          stale = false;
        },
        onspeechstart: (samples) => {
          reader.speechStarted();
          caption = '';
          recorder.begin(samples);
          transcriber?.begin(samples);
          if (phase === 'listening') phase = 'hearing';
        },
        onaudio: (samples) => {
          recorder.append(samples);
          transcriber?.append(samples);
        },
        ondiscard: () => {
          reader.discarded(messages);
          recorder.discard();
          transcriber?.discard();
          caption = '';
          if (phase === 'hearing') phase = 'listening';
        },
        onturn: (durationMs) => {
          reader.committed(messages);
          const samples = recorder.take();
          // Both start now, so a slow turn doesn't delay the next one's upload.
          const clean = samples?.length
            ? transcribeTurn({ accountId, chatId, samples, sampleRate: TURN_RATE }).catch((error) => ({
                text: '',
                signedId: null,
                error: error?.message,
              }))
            : Promise.resolve({ text: '', signedId: null, error: null });
          enqueue(transcriber.commit(), durationMs, clean);
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
    reader.close();
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
  function enqueue(transcript, durationMs, clean) {
    if (phase === 'hearing') phase = 'transcribing';
    queue = queue
      .then(() => handleTurn(transcript, durationMs, clean))
      .catch((error) => logging.error('voice turn failed', error));
  }

  // The recording's ElevenLabs text decides the turn. It is not held for the
  // live caption: a clean result sends at once, while the caption is still
  // only provisional (Mira, #761 review). Only when the clean text is missing
  // does the turn wait for the live caption, to send it marked as rough.
  // transcribeTurn bounds the clean request itself; this backstop keeps the
  // queue moving if a caller hands in an unbounded promise.
  async function handleTurn(transcript, durationMs, clean) {
    if (ended) return;
    phase = 'transcribing';
    note = '';
    let current = true;
    const live = Promise.resolve(transcript).then(
      (value) => ({ text: stripReleasePhrase(value).text, error: null }),
      (error) => ({ text: '', error })
    );
    live.then(({ text }) => {
      if (current && !ended) {
        caption = '';
        provisional = text;
      }
    });
    const recording = await settleWithin(clean, CLEAN_BACKSTOP_MS, { text: '', signedId: null, error: 'timeout' });
    if (ended) return;
    const cleanText = stripReleasePhrase(recording?.text || '').text;
    let liveText = '';
    let liveError = null;
    if (!cleanText.trim()) ({ text: liveText, error: liveError } = await live);
    current = false;
    caption = '';
    provisional = '';
    if (ended) return;
    const { text } = turnContent({ clean: cleanText, live: liveText });
    if (!text) {
      note = liveError && !recording?.signedId
        ? liveError?.message || 'Transcription failed.'
        : `Heard ${Math.round(durationMs / 1000)}s of sound but no words.`;
      phase = 'listening';
      return;
    }
    await send(text, recording?.signedId || null);
  }

  function settleWithin(promise, ms, fallback) {
    let timer;
    return Promise.race([
      Promise.resolve(promise).catch(() => fallback),
      new Promise((resolve) => (timer = setTimeout(() => resolve(fallback), ms))),
    ]).finally(() => clearTimeout(timer));
  }

  async function send(text, audioSignedId) {
    phase = 'sending';
    const { ok, status, data } = await postVoiceMessage({
      accountId,
      chatId,
      userId,
      text,
      audioSignedId,
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
    reader.close();
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
  {#if speaking}
    <p class="text-sm line-clamp-4" data-testid="voice-mode-reply">
      <span class="font-medium">{speaking.author_name || 'Reply'}:</span>
      {speaking.content}
    </p>
  {/if}
  {#if caption}
    <p class="text-sm" data-testid="voice-mode-caption">{caption}</p>
  {/if}
  {#if provisional}
    <p class="text-sm text-muted-foreground animate-pulse" data-testid="voice-mode-provisional">
      {provisional} <span class="text-xs">(in progress)</span>
    </p>
  {/if}
  {#if heard}
    <p class="text-xs text-muted-foreground truncate" data-testid="voice-mode-heard">Sent: “{heard}”</p>
  {/if}
</div>
