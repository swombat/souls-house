import { writable } from 'svelte/store';

// Plays speech while it is still being made (YNwVle): Phonon hands over each
// chunk of samples as soon as it exists (speak's onAudio), and each chunk is
// scheduled on a Web Audio clock right behind the one before, so the first
// sound comes with the first chunk instead of after the whole message.
//
// The context is made inside the tap that asked for the speech (phones only
// let a page make sound from a tap), before anything is awaited.
//
// While the speech is being made the player can pause and play on. Once it is
// all made (finish()), it also seeks: the chunks are joined and played from
// the asked-for second. It ends when everything made has been heard and
// nothing more is coming; then Listen hands the message to the ordinary
// player with the kept WAV, for a replay.
//
// state: { playing, position, duration, done, ended } in seconds, where
// duration is what has been made so far (the whole length once done).

export const LEAD = 0.08; // seconds between the first chunk arriving and its sound

export function createStreamPlayer({
  context = () => new (globalThis.AudioContext || globalThis.webkitAudioContext)(),
  onended,
} = {}) {
  const ctx = context();
  ctx.resume?.()?.catch?.(() => {});
  const state = writable({ playing: false, position: 0, duration: 0, done: false, ended: false });
  const chunks = [];
  let rate = 24000;
  let made = 0; // samples made so far
  let sources = new Set();
  let anchor = null; // context time at which position 0 is (or would have been) heard
  let scheduledEnd = 0; // context time at which the last scheduled sample ends
  let paused = false;
  let done = false;
  let ended = false;
  let stopped = false;
  let generation = 0;

  const seconds = () => made / rate;
  const position = () => {
    if (anchor === null) return 0;
    return Math.max(0, Math.min(ctx.currentTime, scheduledEnd) - anchor);
  };
  const publish = () =>
    state.set({
      playing: anchor !== null && !paused && !ended,
      position: ended ? seconds() : position(),
      duration: seconds(),
      done,
      ended,
    });

  function finishIfHeard() {
    if (ended || stopped || !done || sources.size > 0) return;
    ended = true;
    publish();
    close();
    onended?.();
  }

  function schedule(samples, offsetSeconds = 0) {
    const buffer = ctx.createBuffer(1, samples.length, rate);
    buffer.getChannelData(0).set(samples);
    const node = ctx.createBufferSource();
    node.buffer = buffer;
    node.connect(ctx.destination);
    // A chunk that comes after the one before has finished (the device made
    // speech slower than it is heard) starts a little ahead, and the clock
    // that measures the position moves with it, so the gap is not counted.
    const earliest = ctx.currentTime + LEAD;
    let at = scheduledEnd;
    if (anchor === null) {
      at = earliest;
      anchor = at - offsetSeconds;
    } else if (at < earliest) {
      anchor += earliest - at;
      at = earliest;
    }
    const mine = generation;
    node.onended = () => {
      sources.delete(node);
      if (mine === generation) finishIfHeard();
    };
    sources.add(node);
    node.start(at);
    scheduledEnd = at + buffer.duration;
  }

  function close() {
    for (const node of sources) {
      node.onended = null;
      try {
        node.stop();
      } catch {
        // already stopped
      }
    }
    sources = new Set();
    if (ctx.state !== 'closed') ctx.close?.()?.catch?.(() => {});
  }

  return {
    state,
    get context() {
      return ctx;
    },
    // One chunk of mono samples, in the order they are made.
    push(samples, sampleRate = rate) {
      if (stopped || done || !samples?.length) return;
      rate = sampleRate;
      const copy = new Float32Array(samples);
      chunks.push(copy);
      made += copy.length;
      schedule(copy);
      publish();
    },
    // Everything is made: nothing more will be pushed.
    finish() {
      if (stopped || done) return;
      done = true;
      publish();
      finishIfHeard();
    },
    get made() {
      return seconds();
    },
    get position() {
      return ended ? seconds() : position();
    },
    pause() {
      if (stopped || ended || paused) return;
      paused = true;
      ctx.suspend?.()?.catch?.(() => {});
      publish();
    },
    play() {
      if (stopped || ended || !paused) return;
      paused = false;
      ctx.resume?.()?.catch?.(() => {});
      publish();
    },
    // Only once everything is made: the joined chunks play from `to` seconds.
    seek(to) {
      if (stopped || ended || !done) return false;
      const all = new Float32Array(made);
      let at = 0;
      for (const chunk of chunks) {
        all.set(chunk, at);
        at += chunk.length;
      }
      const from = Math.max(0, Math.min(to, seconds()));
      generation += 1;
      for (const node of sources) {
        node.onended = null;
        try {
          node.stop();
        } catch {
          // already stopped
        }
      }
      sources = new Set();
      anchor = null;
      scheduledEnd = 0;
      const rest = all.subarray(Math.floor(from * rate));
      if (!rest.length) {
        finishIfHeard();
        return true;
      }
      schedule(rest, from);
      publish();
      return true;
    },
    // Tick for the page's progress bar (Web Audio has no timeupdate event).
    tick: publish,
    // Stops the sound and releases the context; nothing plays after this.
    stop() {
      if (stopped) return;
      stopped = true;
      generation += 1;
      close();
      publish();
    },
    get stopped() {
      return stopped;
    },
  };
}
