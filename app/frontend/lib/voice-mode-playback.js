// Voice mode playback (YMaddY, PR 2): resident messages read aloud one at a
// time through a single audio element, streamed from Messages::SpeechesController.
//
// Phones only let a page play sound after a tap, and only on an element that
// was started inside that tap. So the wave button's tap calls unlockAudio(),
// which starts the shared element on a short silent WAV; the panel then plays
// every reply through that same element.
//
// Interruption is playback only: when the person starts speaking, what is
// playing stops and the queue is cleared. A generation counter makes sure a
// play() already in flight when that happens cannot start afterwards.

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
  let generation = 0;

  const report = () => onchange?.(current ? current.id : null);

  function finish(item) {
    if (item !== current) return;
    current = null;
    next();
  }

  function next() {
    const item = queue.shift();
    if (!item) return report();
    current = item;
    report();
    audio.src = urlFor(item.id);
    const started = audio.play();
    started?.catch?.(() => item.generation === generation && finish(item));
  }

  const onended = () => current && finish(current);
  audio.addEventListener('ended', onended);
  audio.addEventListener('error', onended);

  return {
    enqueue(id) {
      queue.push({ id, generation });
      if (!current) next();
    },
    interrupt() {
      generation += 1;
      queue = [];
      if (!current) return;
      current = null;
      audio.pause();
      audio.removeAttribute('src');
      audio.load?.();
      report();
    },
    close() {
      this.interrupt();
      audio.removeEventListener('ended', onended);
      audio.removeEventListener('error', onended);
    },
    get speaking() {
      return current !== null;
    },
  };
}
