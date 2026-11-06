import { onDestroy, onMount, untrack } from 'svelte';
import { captureSupported, startCapture } from '$lib/voice-mode-capture';
import { stripReleasePhrase, voiceModeStatus } from '$lib/voice-mode';
import { createTranscriber } from '$lib/voice-mode-realtime';
import { holdForRecording } from '$lib/recording-guard';
import { micErrorMessage } from '$lib/mic-recorder';
import { postVoiceMessage, requestVoiceSession } from '$lib/voice-mode-api';
import { createVoiceTrace } from '$lib/voice-mode-trace';
import { watchDevices } from '$lib/voice-mode-devices';
import { createEngineReader } from '$lib/voice-mode-reader';
import { createTurnRecorder, turnContent } from '$lib/voice-mode-turn-audio';
import { resolveTurn, startCleanTurn } from '$lib/voice-mode-turn-flow';
import { createHeldTurns, heldStorageKey, newTurnIdentity } from '$lib/voice-mode-held';
import { createWakeLock, online, pageVisible, watchPage } from '$lib/voice-mode-lifecycle';
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
//
// No turn is dropped (jMapOj): one that fails anywhere after the detector
// closed it is held in the panel with Retry and Discard, later turns wait
// behind it, and the queue retries itself once when the page is visible and
// online again (voice-mode-held.js). When the browser stops the microphone
// (screen off, the system taking the mic), the open turn is closed so what
// was said goes through that path, the panel says it is paused, and it picks
// up again when the page is back (voice-mode-lifecycle.js).
// endDrainMs: how long End waits for turns in flight before closing (tests shorten it).
export function createVoiceModeSession(props) {
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
  // Why the browser stopped the microphone, or null (voiceModeStatus).
  let paused = $state(null);
  let held = $state([]);
  let speakingId = $state(null);
  // The reply being read, shown as text too: on a phone the panel is the only
  // evidence that a reply exists while the person is talking.
  const speaking = $derived(speakingId ? (props.messages || []).find((m) => m.id === speakingId) : null);

  const reader = createEngineReader(() => props.messages || [], {
    onchange: (id) => (speakingId = id),
    onnote: (text) => (note = text),
  });
  $effect(() => reader.take(props.messages || []));

  let capture = null;
  let transcriber = null;
  const TURN_RATE = 24_000;
  const recorder = createTurnRecorder({ sampleRate: TURN_RATE });
  let releaseHold = null;
  let queue = Promise.resolve();
  let ended = false;
  // The house refused voice mode (403): later turns are not sent.
  let refused = false;
  let lastSampleAt = 0;
  let watchdog = null;

  const busy = $derived(!paused && (phase === 'transcribing' || phase === 'sending'));
  const status = $derived(voiceModeStatus({ phase, muted, note, speaking: speakingId, paused }));

  const SEND_TIMEOUT_MS = 20_000;
  const STALE_MS = 3000;

  const queueOfHeld = createHeldTurns({
    // One panel per conversation: the key is fixed when it opens.
    key: heldStorageKey(untrack(() => props.chatId)),
    deliver: deliverHeld,
    onchange: (list) => (held = list),
  });
  held = queueOfHeld.list();
  const wakeLock = createWakeLock();
  let stopWatching = null;
  let stopDevices = null;
  const trace = createVoiceTrace();
  // Audio devices changed mid-turn: reopen the mic once the turn closes.
  let rerouteWanted = false;

  // The handlers the microphone feeds; kept so a reopened mic gets the same.
  const captureHandlers = {
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
      reader.discarded(props.messages || []);
      recorder.discard();
      transcriber?.discard();
      caption = '';
      if (phase === 'hearing') phase = 'listening';
      if (rerouteWanted) reroute();
    },
    onturn: (durationMs) => {
      trace.note(`turn:${(durationMs / 1000).toFixed(1)}s`);
      reader.committed(props.messages || []);
      // The caption as shown: if the transcriber's final answer is lost with
      // the connection, these are still the person's words (jNwAdJ YVvdnw).
      const shown = caption;
      const samples = recorder.take();
      // Both start now, so a slow turn doesn't delay the next one's upload.
      const clean = startCleanTurn({
        accountId: props.accountId,
        chatId: props.chatId,
        samples,
        sampleRate: TURN_RATE,
      });
      let transcript;
      try {
        transcript = transcriber.commit();
      } catch (error) {
        transcript = Promise.reject(error);
      }
      enqueue(transcript, durationMs, clean, { caption: shown, samples, clientMessageId: newTurnIdentity() });
      if (rerouteWanted) reroute();
    },
    oninterrupt: (reason) => {
      trace.note(`int:${reason}`);
      pause(reason === 'ended' ? 'hidden' : reason);
    },
    onrestore: () => {
      trace.note('restore');
      if (paused && pageVisible()) resume();
    },
  };

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
      capture = await startCapture(captureHandlers);
      if (ended) {
        await capture.stop();
        return;
      }
      phase = 'listening';
      lastSampleAt = performance.now();
      wakeLock.acquire();
      stopWatching = watchPage({
        onvisible: () => {
          trace.note('visible');
          wakeLock.reacquire();
          if (paused || stale || (capture && !capture.running)) resume();
          else retryHeld();
        },
        // Hidden alone is not a pause: Chrome on Android may keep a hidden
        // page's microphone running. The watchdog pauses once samples stop.
        onhidden: () => trace.note('hidden'),
        onpagehide: () => {
          trace.note('pagehide');
          pause('hidden');
        },
        ononline: () => retryHeld(),
      });
      // Samples stop when the browser suspends the page (a locked phone, a
      // backgrounded tab). When the page is hidden that is a pause: close the
      // open turn so it is sent (or held). When visible, say so and try to
      // wake the audio engine.
      watchdog = setInterval(() => {
        if (muted || paused || phase === 'failed' || phase === 'starting') return;
        stale = performance.now() - lastSampleAt > STALE_MS;
        if (!stale) return;
        trace.note(pageVisible() ? 'stale:visible' : 'stale:hidden');
        if (!pageVisible()) pause('hidden');
        else capture?.resume();
      }, 1000);
      stopDevices = watchDevices({
        onchange: () => {
          trace.note('devices');
          rerouteWanted = true;
          if (phase !== 'hearing') reroute();
        },
      });
      // Turns held from before a reload of this tab: try them once.
      if (queueOfHeld.size) retryHeld();
    } catch (error) {
      phase = 'failed';
      note = micErrorMessage(error);
      props.onerror?.(note);
      transcriber?.close();
      releaseHold?.();
      releaseHold = null;
    }
  });

  onDestroy(() => {
    ended = true;
    reader.close();
    clearInterval(watchdog);
    stopWatching?.();
    stopDevices?.();
    wakeLock.release();
    capture?.stop();
    transcriber?.close();
    releaseHold?.();
  });

  // A fresh short-lived secret for each (re)connection.
  async function fetchSession() {
    const { ok, status, data } = await requestVoiceSession(props.accountId, props.chatId, { trace: trace.take() });
    if (!ok) {
      const message = data?.error || 'Transcription could not start.';
      if (status === 403) {
        props.onerror?.(message);
        end({ drain: false });
      }
      throw new Error(message);
    }
    return data;
  }

  // Turns closed and not yet settled, by identity. End writes each one still
  // here to the held queue (and so to sessionStorage) before it closes, and
  // the turn's late result then settles that same record (#797 review).
  const inFlight = new Map();

  // Turns are sent one at a time, in the order they were spoken; each
  // transcript is already on its way when the next turn starts. Nothing thrown
  // in here is only logged: whatever is known of the turn is held.
  function enqueue(transcript, durationMs, clean, { caption: shown = '', samples = null, clientMessageId } = {}) {
    if (phase === 'hearing') phase = 'transcribing';
    const meta = { clientMessageId, caption: shown, durationMs, heldId: null };
    inFlight.set(clientMessageId, meta);
    queue = queue
      .then(() => handleTurn(transcript, durationMs, clean, { samples, meta }))
      .catch((error) => {
        logging.error('voice turn failed', error);
        keep(meta, { text: roughOf(shown), samples, error: error?.message || 'Something went wrong with this turn.' });
        afterTurn();
      })
      .finally(() => inFlight.delete(clientMessageId));
  }

  // Holds a turn, or fills in the record End already made for it.
  function keep(meta, { text = '', signedId = null, samples = null, error = '', state = 'failed' }) {
    if (meta.heldId) {
      const fields = { error, state };
      if (text) fields.text = text;
      if (signedId) fields.signedId = signedId;
      queueOfHeld.update(meta.heldId, fields);
      return;
    }
    meta.heldId = queueOfHeld.hold({
      text,
      signedId,
      samples,
      durationMs: meta.durationMs,
      error,
      state,
      clientMessageId: meta.clientMessageId,
    });
  }

  // A turn End held that has now been sent: its record goes.
  function settled(meta) {
    if (meta.heldId) queueOfHeld.discard(meta.heldId);
    meta.heldId = null;
  }

  const roughOf = (text) => turnContent({ clean: '', live: stripReleasePhrase(text).text }).text;

  // The clean (recording) text decides the turn; the live caption is shown as
  // provisional meanwhile and sent marked rough only if the clean text is missing
  // (see voice-mode-turn-flow.js).
  //
  // A turn closed before End (or before leaving the page) is still delivered
  // after it: End waits a few seconds, writes what it has of each unsettled
  // turn to the held queue, and closes; the turn's late result then sends and
  // settles that record, or fills it in (Mira, #797 review).
  async function handleTurn(transcript, durationMs, clean, { samples = null, meta }) {
    if (refused) return;
    if (!ended) {
      phase = 'transcribing';
      note = '';
    }
    const turn = await resolveTurn({
      transcript,
      clean,
      durationMs,
      caption: meta.caption,
      onProvisional: (text) => {
        // The live text as it arrives, after commit too: what End writes down
        // is the latest the person saw (Mira, #797 review).
        meta.caption = text;
        if (ended && meta.heldId) queueOfHeld.update(meta.heldId, { text: roughOf(text) });
        if (!ended) [caption, provisional] = ['', text];
      },
    });
    if (!ended) {
      caption = '';
      provisional = '';
    }
    if (refused) return;
    // Another panel (this chat, reopened after End) already sent or discarded
    // this turn: Discard there is final here too.
    if (queueOfHeld.finished(meta.clientMessageId)) {
      afterTurn();
      return;
    }
    if (turn.failed) {
      keep(meta, { text: ended ? roughOf(meta.caption) : '', signedId: turn.signedId, samples, error: turn.note });
      afterTurn();
      return;
    }
    if (!turn.text) {
      if (!ended) note = turn.note;
      settled(meta);
      afterTurn();
      return;
    }
    // Behind another held turn: wait in line, and try the line again now.
    const ahead = held.some((item) => item.id !== meta.heldId);
    if (ahead) {
      keep(meta, { text: turn.text, signedId: turn.signedId, state: 'waiting' });
      afterTurn();
      retryHeld({ auto: false });
      return;
    }
    if (queueOfHeld.finished(meta.clientMessageId)) return afterTurn();
    const result = await send(turn.text, turn.signedId, meta.clientMessageId);
    if (result.ok) settled(meta);
    else if (!result.fatal) keep(meta, { text: turn.text, signedId: turn.signedId, error: result.error });
    afterTurn();
  }

  function afterTurn() {
    if (!ended && phase !== 'failed') phase = 'listening';
  }

  // One post. Resolves { ok, error, fatal }; a 403 (the mode was switched off
  // under us) ends voice mode.
  async function send(text, audioSignedId, clientMessageId = null) {
    if (!ended) phase = 'sending';
    const { ok, status, data } = await postVoiceMessage({
      accountId: props.accountId,
      chatId: props.chatId,
      userId: props.userId,
      text,
      audioSignedId,
      clientMessageId,
      timeoutMs: SEND_TIMEOUT_MS,
    });
    if (!ok) {
      const errors = data?.errors;
      const error = Array.isArray(errors)
        ? errors.join(', ')
        : errors || (status === null ? 'The house could not be reached.' : 'Could not send what you said.');
      // 403: the mode was switched off (or lost its key) under us. Stop listening.
      if (status === 403) {
        refused = true;
        if (!ended) {
          note = error;
          props.onerror?.(note);
          await end({ drain: false });
        }
        return { ok: false, error, fatal: true };
      }
      return { ok: false, error, fatal: false };
    }
    sent += 1;
    if (!ended) {
      heard = text;
      props.onsent?.(data);
    }
    return { ok: true, error: '', fatal: false };
  }

  // A held turn, sent again: transcribed again first when it has no text yet.
  async function deliverHeld(item) {
    if (ended) return { ok: false, fatal: true, error: item.error };
    let { text, signedId } = item;
    if (!text?.trim()) {
      if (!item.samples?.length) return { ok: false, error: 'The recording was lost when the page reloaded.' };
      const recording = await startCleanTurn({
        accountId: props.accountId,
        chatId: props.chatId,
        samples: item.samples,
        sampleRate: TURN_RATE,
      });
      signedId = recording.signedId || signedId;
      // A failed transcript is a failure, kept or not: only a clean answer
      // with no words lets the turn go (Mira, #797 review).
      if (recording.error) return { ok: false, error: recording.error, signedId };
      text = stripReleasePhrase(recording.text || '').text;
      if (!text) return { ok: false, dropped: true, text: '', signedId };
    }
    // Sent or discarded by another panel of this chat meanwhile.
    if (queueOfHeld.finished(item.clientMessageId)) return { ok: false, dropped: true, text, signedId };
    const result = await send(text, signedId, item.clientMessageId);
    if (!ended && phase === 'sending') phase = 'listening';
    return { ...result, text, signedId };
  }

  function retryHeld({ auto = true } = {}) {
    if (ended || !queueOfHeld.size) return;
    if (auto && (!pageVisible() || !online())) return;
    queueOfHeld.drain({ auto }).catch((error) => logging.error('voice held retry failed', error));
  }

  // The browser stopped the microphone. Close the open turn now, while its
  // samples are still here, so what was said is sent or held; then wait for
  // the page to come back.
  function pause(reason) {
    if (ended || paused || !capture) return;
    trace.note(`pause:${reason}`);
    paused = reason;
    try {
      capture.flush();
    } catch (error) {
      logging.error('voice flush on pause failed', error);
    }
  }

  // Back: wake the audio engine, reopen the mic if the track ended, reconnect
  // the transcriber, then retry what is held. No tap needed where the browser
  // allows it; if it refuses, the panel says so and End still works.
  let resuming = null;
  function resume() {
    if (ended || resuming) return resuming;
    resuming = (async () => {
      try {
        if (stale && !paused) pause('hidden');
        if (capture && (!capture.alive || rerouteWanted)) {
          rerouteWanted = false;
          const old = capture;
          capture = null;
          await old.stop().catch(() => {});
          capture = await startCapture(captureHandlers);
          if (ended) {
            await capture.stop();
            return;
          }
          if (muted) capture.mute(true);
        } else {
          await capture?.resume();
        }
        transcriber?.connect().catch((error) => (note = error.message));
        paused = null;
        stale = false;
        lastSampleAt = performance.now();
        retryHeld();
      } catch (error) {
        note = `The microphone could not be reopened: ${micErrorMessage(error)}`;
      } finally {
        resuming = null;
      }
    })();
    return resuming;
  }

  // The audio devices changed (a headset joined or left): reopen the mic so
  // the phone picks its route again (voice-mode-devices.js). Between turns
  // only; a paused panel reopens on resume anyway.
  function reroute() {
    if (ended || !capture) return null;
    // Paused or already reopening: resume reopens the mic while this is set.
    if (paused || resuming) return resuming;
    rerouteWanted = false;
    resuming = (async () => {
      try {
        const old = capture;
        capture = null;
        await old.stop().catch(() => {});
        capture = await startCapture(captureHandlers);
        if (ended) {
          await capture.stop();
          return;
        }
        if (muted) capture.mute(true);
        lastSampleAt = performance.now();
      } catch (error) {
        note = `The microphone could not be reopened: ${micErrorMessage(error)}`;
      } finally {
        resuming = null;
      }
    })();
    return resuming;
  }

  function retryFront() {
    retryHeld({ auto: false });
  }

  function discardHeld(id) {
    const front = held[0]?.id === id;
    queueOfHeld.discard(id);
    // The front went: the next one may be fine to send.
    if (front) retryHeld({ auto: false });
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
    stopWatching?.();
    stopDevices?.();
    wakeLock.release();
    const open = capture;
    capture = null;
    await open?.stop();
    if (drain) await Promise.race([queue, new Promise((resolve) => setTimeout(resolve, props.endDrainMs ?? 6000))]);
    // What is still on its way is written down now, before the panel goes:
    // its caption as rough text and its identity, so a reopened panel can send
    // it and the late result can settle the same record.
    for (const meta of inFlight.values()) {
      if (!meta.heldId) {
        keep(meta, { text: roughOf(meta.caption), error: 'Voice mode ended before this turn was sent.' });
      }
    }
    ended = true;
    transcriber?.close();
    releaseHold?.();
    releaseHold = null;
    props.onend?.({ sent });
  }

  const meter = $derived(Math.min(100, Math.round((level / Math.max(threshold * 4, 0.001)) * 100)));

  // What the panel shows and the controls it offers.
  return {
    get phase() {
      return phase;
    },
    get muted() {
      return muted;
    },
    get busy() {
      return busy;
    },
    get status() {
      return status;
    },
    get meter() {
      return meter;
    },
    get stale() {
      return stale;
    },
    get paused() {
      return paused;
    },
    get note() {
      return note;
    },
    get speaking() {
      return speaking;
    },
    get caption() {
      return caption;
    },
    get provisional() {
      return provisional;
    },
    get heard() {
      return heard;
    },
    get held() {
      return held;
    },
    toggleMute,
    end,
    retryFront,
    discardHeld,
  };
}
