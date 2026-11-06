// What the phone did to the microphone, written down so the house can see it
// (jBVWGj, Daniel's Pixel trial 6 Nov: with the screen off the page kept
// running but the turn closed after 4.4 s, and nothing said why).
//
// The panel notes each lifecycle signal as it happens: the page hidden or
// shown, the track muted or ended, the audio engine suspended, samples going
// stale, a pause, a turn closing (with its length), the audio devices changing.
// take() hands back what was noted since the last take, as one short line like
// "hidden@0.0,int:muted@0.4,pause:muted@0.4,turn:4.4s@0.4,visible@61.2"
// (seconds from the first note), and starts again. The panel sends that line
// with its next transcription session request, so it lands in the web log.
// Names only, never audio or words.

const LIMIT = 40;
const MAX_LENGTH = 600;

export function createVoiceTrace({ now = () => globalThis.performance.now() } = {}) {
  let events = [];
  let origin = null;
  return {
    note(name) {
      const at = now();
      if (origin === null) origin = at;
      events.push(`${name}@${((at - origin) / 1000).toFixed(1)}`);
      if (events.length > LIMIT) events = events.slice(-LIMIT);
    },
    take() {
      const line = events.join(',').slice(-MAX_LENGTH);
      events = [];
      origin = null;
      return line;
    },
  };
}
