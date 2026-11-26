// One take of Record now: the microphone, the MediaRecorder and the chunks it
// hands over, kept out of the dialog so its lifecycle can be tested alone.
//
// Only the recorder's `stop` event finishes a take. A browser can go inactive,
// report an error, and only then deliver the last `dataavailable` and `stop`
// (an iPhone locking its screen, a call coming in), so becoming inactive is not
// the end of the audio. If `stop` never comes, a bounded fallback finishes the
// take with what has arrived. `dispose()` lets go of everything, including a
// permission prompt that answers after the take was abandoned.
import { micErrorMessage, recorderOptions, stopStream } from './mic-recorder.js';

export const STOP_FALLBACK_MS = 2000;

export function createTake({
  onLive = () => {},
  onEnded = () => {},
  onFailed = () => {},
  media = () => globalThis.navigator?.mediaDevices,
  Recorder = () => globalThis.MediaRecorder,
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (id) => clearTimeout(id),
} = {}) {
  let disposed = false;
  let stream = null;
  let recorder = null;
  let chunks = [];
  let stopAsked = false;
  let reason = '';
  let fallback = null;
  let finished = false;

  function release() {
    if (fallback) clearTimer(fallback);
    fallback = null;
    stopStream(stream);
    stream = null;
  }

  function finish() {
    if (finished || disposed) return;
    finished = true;
    const mimeType = recorder?.mimeType || '';
    release();
    if (!stopAsked && !reason) reason = 'The recording stopped on its own. What was captured is below.';
    onEnded({ chunks: chunks.slice(), mimeType, reason });
  }

  // Ask the recorder to stop; its `stop` event (or the fallback) finishes.
  function end(why = '') {
    if (finished || disposed || !recorder) return;
    if (why && !reason) reason = why;
    if (!fallback) fallback = setTimer(finish, STOP_FALLBACK_MS);
    if (recorder.state !== 'inactive') {
      try {
        recorder.stop();
      } catch {
        // Already stopping; the stop event or the fallback finishes.
      }
    }
  }

  async function start() {
    const devices = media();
    if (!devices?.getUserMedia) {
      onFailed("This browser can't record here. Try Bring in a recording.");
      return;
    }
    let granted;
    try {
      granted = await devices.getUserMedia({ audio: true });
    } catch (err) {
      if (!disposed) onFailed(micErrorMessage(err));
      return;
    }
    if (disposed) {
      stopStream(granted);
      return;
    }
    stream = granted;
    try {
      const Ctor = Recorder();
      recorder = new Ctor(stream, recorderOptions(Ctor));
      recorder.ondataavailable = (event) => {
        if (event.data?.size) chunks.push(event.data);
      };
      recorder.onstop = finish;
      recorder.onerror = () => end('The recording stopped unexpectedly. What was captured is below.');
      stream.getAudioTracks?.().forEach((track) => {
        track.onended = () => end('The microphone stopped (the screen may have locked). What was captured is below.');
      });
      // A timeslice keeps what has been said in hand even if the take is cut off.
      recorder.start(1000);
    } catch {
      release();
      recorder = null;
      onFailed('Could not start recording');
      return;
    }
    onLive(new Date());
  }

  return {
    start,
    stop() {
      stopAsked = true;
      end();
    },
    // Whether the recorder is still taking audio; the dialog's timer asks.
    get recording() {
      return !finished && !disposed && recorder?.state === 'recording';
    },
    // Noticed by the timer: the recorder went quiet without telling us.
    lost() {
      end('The recording stopped. What was captured is below.');
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      if (recorder) {
        recorder.ondataavailable = null;
        recorder.onstop = null;
        recorder.onerror = null;
        try {
          if (recorder.state !== 'inactive') recorder.stop();
        } catch {
          // Nothing to keep.
        }
      }
      release();
    },
  };
}
