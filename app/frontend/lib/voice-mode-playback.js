import { createStreamPlayer } from '$lib/stream-player';

// Voice mode playback (YMaddY, PR 2): resident messages read aloud one at a
// time through a single audio element, streamed from Messages::SpeechesController.
//
// Phones only let a page play sound after a tap, and only on an element that
// was started inside that tap. So the wave button's tap calls unlockAudio(),
// which starts the shared element on a short silent WAV; the panel then plays
// every reply through that same element.
//
// Interruption is playback only: when the person starts speaking, what is
// playing pauses and the queue is cleared. interrupt() returns what it stopped
// as { id, at, playing } entries (the reply playing, with its real position in
// seconds, then the ones queued behind it), so the reader can put the whole
// sequence back afterwards (#748, #758).
//
// The reply that was playing is parked, not torn down: the element keeps its
// source and what it has already received. The speech is made live and never
// stored, so this element is the only copy of that audio; enqueue(id, { resume:
// true }) plays on from where it paused, as many times as it is interrupted.
// A restart, or a resume whose parked stream has died, is a fresh request from
// the top: a reply can be heard twice, never skipped.
// A generation counter makes sure a play() already in flight when that
// happens cannot start afterwards.
//
// Under Phonon a reply is spoken while it is still being made, as Listen does
// (YNwVle, #895): the speech source hands over each chunk (onAudio), and the
// first chunk starts a stream player (lib/stream-player.js) on the Web Audio
// context the wave button's tap unlocked, so the first sound comes with the
// first chunk instead of after the whole reply. An interruption pauses that
// stream and parks it, and the making carries on into it, so a resume plays
// on from where it paused. A reply already made (a replay) still plays through
// the audio element from its kept WAV, and ElevenLabs is streamed by the
// element from its URL as before.

let shared = null;
let sharedCtx = null;

export function sharedAudio() {
  if (!shared && typeof Audio !== 'undefined') shared = new Audio();
  return shared;
}

// A tenth of a second of 8 kHz mono silence, as a WAV data URI.
export function silentWav(samples = 800) {
  const bytes = new Uint8Array(44 + samples);
  const view = new DataView(bytes.buffer);
  const text = (offset, value) => [...value].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
  text(0, 'RIFF');
  view.setUint32(4, 36 + samples, true);
  text(8, 'WAVEfmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, 8000, true);
  view.setUint32(28, 8000, true);
  view.setUint16(32, 1, true);
  view.setUint16(34, 8, true); // 8-bit: silence is 128
  text(36, 'data');
  view.setUint32(40, samples, true);
  bytes.fill(128, 44);
  let binary = '';
  bytes.forEach((b) => (binary += String.fromCharCode(b)));
  return `data:audio/wav;base64,${btoa(binary)}`;
}

// The Web Audio context Phonon's streamed replies play on. Made (or woken)
// inside the tap that opens voice mode, for the same reason as the element.
export function sharedContext() {
  const Context = globalThis.AudioContext || globalThis.webkitAudioContext;
  if ((!sharedCtx || sharedCtx.state === 'closed') && Context) sharedCtx = new Context();
  return sharedCtx;
}

// Call from inside the tap that opens voice mode.
export function unlockAudio(audio = sharedAudio(), context = sharedContext) {
  context?.()
    ?.resume?.()
    ?.catch?.(() => {});
  if (!audio) return;
  audio.src = silentWav();
  audio.play()?.catch?.(() => {});
}

// A stream only on a context that can actually play: one that is running, or
// (trusted) one this player has streamed on before and suspended itself to
// park a reply. A context that never started (Read replies aloud switched on
// with no tap, #895 review) leaves the reply to the element, whose refused
// play() is what shows Tap to play.
function sharedStream({ trusted = false, ...options } = {}) {
  const ctx = sharedContext();
  if (!ctx || (ctx.state !== 'running' && !trusted)) return null;
  return createStreamPlayer({ context: sharedContext, keepContext: true, ...options });
}

export function createPlayer({ audio = sharedAudio(), urlFor, onchange, onerror, stream = sharedStream } = {}) {
  let queue = [];
  let current = null;
  let parked = null;
  let generation = 0;
  let closed = false;
  let streamed = false; // a stream has played on this context

  const report = () => onchange?.(current ? current.id : null);

  function finish(item) {
    if (item !== current) return;
    current = null;
    next();
  }

  // A resumed reply that cannot play on is asked for again from the top. Any
  // other failure is reported (an interruption's abort is not a failure) and
  // the queue moves on.
  function failed(item, error) {
    if (item !== current) return;
    if (item.resumed) {
      current = null;
      queue.unshift({ id: item.id, generation });
      return next();
    }
    if (error && error.name !== 'AbortError') onerror?.(item.id, error);
    finish(item);
  }

  // Each request for a reply's audio is a job: its making (controller) and,
  // under Phonon, the stream it plays into. A streamed job outlives the item
  // that asked for it: interrupting parks the job, and the resumed item takes
  // it over, so the making's outcome is always routed to whoever holds the job
  // now (#1040 review).
  //
  // A parked job that will not be played on is stopped and its making aborted.
  function dropParked() {
    parked?.job?.stream?.stop();
    parked?.job?.controller?.abort();
    parked = null;
  }

  function streamEnded(job) {
    if (current?.job === job) return finish(current);
    if (parked?.job === job) parked = null;
  }

  // The first chunk of a reply being made starts its stream, if the context
  // can play; otherwise the whole reply goes to the element when it is made.
  // An item interrupted before any sound came has nothing to park (its making
  // is aborted).
  function onAudioFor(item, job) {
    return (samples, sampleRate) => {
      if (closed || job.element) return;
      if (!job.stream) {
        if (item !== current || item.generation !== generation) return;
        const s = stream?.({ trusted: streamed, onended: () => streamEnded(job) });
        if (!s) {
          job.element = true;
          return;
        }
        streamed = true;
        job.stream = s;
        item.started = true;
      }
      job.stream.push(samples, sampleRate);
    };
  }

  // A streamed job's making failed: the stream stops, and whoever holds the
  // job now fails as any reply does (a resumed one is asked for again from the
  // top, otherwise reported and the queue moves on).
  function jobFailed(job, error) {
    job.stream.stop();
    if (parked?.job === job) parked = null;
    if (current?.job !== job) return;
    const holder = current;
    holder.job = null;
    holder.started = false;
    failed(holder, error);
  }

  // The source is set only now, so an item still being made (Phonon) never
  // counts as playing: an interruption before this point parks nothing.
  function start(item, url) {
    if (item.job?.stream) return item.job.stream.finish(); // heard as it was made
    if (closed || item !== current || item.generation !== generation) return;
    if (!url) return failed(item, new Error('No audio for this reply.'));
    item.started = true;
    audio.src = url;
    play(item, audio.play());
  }

  function play(item, started) {
    started?.catch?.((error) => item.generation === generation && failed(item, error));
  }

  function next() {
    const item = queue.shift();
    if (!item) return report();
    current = item;
    report();
    if (item.resume && parked?.id === item.id && parked.job?.stream && !parked.job.stream.stopped) {
      item.resumed = true;
      item.started = true;
      item.job = parked.job;
      parked = null;
      item.job.stream.play();
      return;
    }
    if (item.resume && parked?.id === item.id && !parked.job && !audio.error) {
      item.resumed = true;
      item.started = true;
      parked = null;
      return play(item, audio.play());
    }
    dropParked();
    // urlFor may answer at once (a URL) or later (a promise of one: Phonon
    // makes the audio first). Interrupting aborts the making.
    const job = { controller: typeof AbortController === 'function' ? new AbortController() : null };
    item.job = job;
    let source;
    try {
      source = urlFor(item.id, { signal: job.controller?.signal, onAudio: onAudioFor(item, job) });
    } catch (error) {
      return failed(item, error);
    }
    if (typeof source?.then === 'function') {
      source.then(
        (url) => (job.stream ? job.stream.finish() : start(item, url)),
        (error) => {
          if (job.stream) return jobFailed(job, error);
          if (item.generation === generation) failed(item, error);
        }
      );
    } else {
      start(item, source);
    }
  }

  // Only a reply whose audio was set ends: the unlock clip (or the previous
  // reply) finishing while the next one is still being made must not skip it.
  const onended = () => current?.started && !current.job?.stream && finish(current);
  // An error while a reply is parked means that source is dead: forget it, so
  // its resume is a fresh request rather than a play() on a broken element.
  const onerrorEvent = () => {
    if (current?.started && !current.job?.stream) return failed(current);
    if (!current && !parked?.job) parked = null;
  };
  audio.addEventListener('ended', onended);
  audio.addEventListener('error', onerrorEvent);

  function stop() {
    generation += 1;
    const started = Boolean(current?.started);
    const now = current?.job?.stream ? current.job.stream.position : audio.currentTime;
    const position = started && Number.isFinite(now) ? now : 0;
    const dropped = [
      ...(current ? [{ id: current.id, at: position, playing: started }] : []),
      ...queue.map((item) => ({ id: item.id, at: 0, playing: false })),
    ];
    queue = [];
    if (current) {
      if (current.job?.stream) {
        // The making carries on into the paused stream, so a resume plays on;
        // it is aborted only if the job is dropped (dropParked).
        parked = { id: current.id, job: current.job };
        current.job.stream.pause();
      } else {
        current.job?.controller?.abort();
        if (started) {
          parked = { id: current.id };
          audio.pause();
        }
      }
      current = null;
      report();
    }
    return dropped;
  }

  return {
    enqueue(id, { resume = false } = {}) {
      if (closed) return;
      queue.push({ id, resume, generation });
      if (!current) next();
    },
    interrupt: stop,
    close() {
      closed = true;
      stop();
      dropParked();
      audio.pause?.();
      audio.removeAttribute('src');
      audio.load?.();
      audio.removeEventListener('ended', onended);
      audio.removeEventListener('error', onerrorEvent);
    },
    get speaking() {
      return current !== null;
    },
  };
}
