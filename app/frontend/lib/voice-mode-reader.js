import { createPlayer } from '$lib/voice-mode-playback';
import { createReplyPicker } from '$lib/voice-mode-replies';
import { createSpeechSource } from '$lib/speech-source';

// The reply side of voice mode (VoiceModePanel): which replies are read
// (the picker) and the one audio element that reads them (the player), tied
// to the speech detector's three moments (#748, #758).
// - speech starts: nothing new is read, and the reply playing and the ones
//   queued behind it are cut off and kept;
// - the burst ends, sent as a turn or discarded as not speech: the cut-off
//   sequence comes back in order, then whatever landed meanwhile. Speaking over
//   a reply never loses it (Daniel, #758: "I do want to hear whatever you have
//   got to say, even if I interrupt it"). The reply that was playing restarts if
//   it had played under RESTART_UNDER seconds, and otherwise plays on from where
//   it paused (the player keeps that audio);
// - End (close) is the only thing that drops it.
export const RESTART_UNDER = 5;

// The audio for each reply comes from the speech source (SpeechEngine): made
// here by Phonon, or ElevenLabs' stream, as the server says for that resident.
// A reply that can't be read is reported through onerror and skipped.
export function createReplyReader({
  messages = [],
  onchange,
  onerror,
  source = createSpeechSource({ mode: 'voice_mode' }),
  audio,
}) {
  const picker = createReplyPicker(messages);
  const player = createPlayer({
    ...(audio ? { audio } : {}),
    urlFor: (id, { signal } = {}) => source.resolve(id, { signal }).then((answer) => answer.url),
    onchange,
    onerror,
  });
  let interrupted = [];
  const read = (ids) => ids.forEach((id) => player.enqueue(id));
  const resume = (current) => {
    const back = interrupted;
    interrupted = [];
    picker.release();
    back.forEach(({ id, at, playing }) => player.enqueue(id, { resume: playing && at >= RESTART_UNDER }));
    read(picker.take(current));
  };

  return {
    take(current) {
      read(picker.take(current));
    },
    speechStarted() {
      picker.hold();
      interrupted = [...interrupted, ...player.interrupt()];
    },
    discarded(current) {
      resume(current);
    },
    committed(current) {
      resume(current);
    },
    // Terminal: once End begins nothing is read during its drain.
    close() {
      interrupted = [];
      player.close();
      source.close();
    },
  };
}
