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

let shared = null;

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

// Call from inside the tap that opens voice mode.
export function unlockAudio(audio = sharedAudio()) {
  if (!audio) return;
  audio.src = silentWav();
  audio.play()?.catch?.(() => {});
}

export function createPlayer({ audio = sharedAudio(), urlFor, onchange, onerror } = {}) {
  let queue = [];
  let current = null;
  let parked = null;
  let generation = 0;
  let closed = false;

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

  // The source is set only now, so an item still being made (Phonon) never
  // counts as playing: an interruption before this point parks nothing.
  function start(item, url) {
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
    if (item.resume && parked?.id === item.id && !audio.error) {
      item.resumed = true;
      item.started = true;
      parked = null;
      return play(item, audio.play());
    }
    parked = null;
    // urlFor may answer at once (a URL) or later (a promise of one: Phonon
    // makes the audio first). Interrupting aborts the making.
    item.controller = typeof AbortController === 'function' ? new AbortController() : null;
    let source;
    try {
      source = urlFor(item.id, { signal: item.controller?.signal });
    } catch (error) {
      return failed(item, error);
    }
    if (typeof source?.then === 'function') {
      source.then(
        (url) => start(item, url),
        (error) => item.generation === generation && failed(item, error)
      );
    } else {
      start(item, source);
    }
  }

  // Only a reply whose audio was set ends: the unlock clip (or the previous
  // reply) finishing while the next one is still being made must not skip it.
  const onended = () => current?.started && finish(current);
  // An error while a reply is parked means that source is dead: forget it, so
  // its resume is a fresh request rather than a play() on a broken element.
  const onerrorEvent = () => {
    if (current?.started) return failed(current);
    if (!current) parked = null;
  };
  audio.addEventListener('ended', onended);
  audio.addEventListener('error', onerrorEvent);

  function stop() {
    generation += 1;
    const started = Boolean(current?.started);
    const position = started && Number.isFinite(audio.currentTime) ? audio.currentTime : 0;
    const dropped = [
      ...(current ? [{ id: current.id, at: position, playing: started }] : []),
      ...queue.map((item) => ({ id: item.id, at: 0, playing: false })),
    ];
    queue = [];
    if (current) {
      current.controller?.abort();
      if (started) {
        parked = { id: current.id };
        audio.pause();
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
      parked = null;
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
