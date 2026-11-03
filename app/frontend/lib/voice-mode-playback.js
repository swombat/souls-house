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

export function createPlayer({ audio = sharedAudio(), urlFor, onchange } = {}) {
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

  // A resumed reply that cannot play on is asked for again from the top.
  function failed(item) {
    if (item !== current) return;
    if (item.resumed) {
      current = null;
      queue.unshift({ id: item.id, generation });
      return next();
    }
    finish(item);
  }

  function next() {
    const item = queue.shift();
    if (!item) return report();
    current = item;
    report();
    let started;
    if (item.resume && parked?.id === item.id) {
      item.resumed = true;
      parked = null;
      started = audio.play();
    } else {
      parked = null;
      audio.src = urlFor(item.id);
      started = audio.play();
    }
    started?.catch?.(() => item.generation === generation && failed(item));
  }

  const onended = () => current && finish(current);
  const onerror = () => current && failed(current);
  audio.addEventListener('ended', onended);
  audio.addEventListener('error', onerror);

  function stop() {
    generation += 1;
    const position = Number.isFinite(audio.currentTime) ? audio.currentTime : 0;
    const dropped = [
      ...(current ? [{ id: current.id, at: position, playing: true }] : []),
      ...queue.map((item) => ({ id: item.id, at: 0, playing: false })),
    ];
    queue = [];
    if (current) {
      parked = { id: current.id };
      current = null;
      audio.pause();
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
      audio.removeAttribute('src');
      audio.load?.();
      audio.removeEventListener('ended', onended);
      audio.removeEventListener('error', onerror);
    },
    get speaking() {
      return current !== null;
    },
  };
}
