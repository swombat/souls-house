import { createPlayer } from '$lib/voice-mode-playback';
import { createReplyPicker } from '$lib/voice-mode-replies';
import { messageSpeechPath } from '@/routes';

// The reply side of voice mode (VoiceModePanel): which replies are read
// (the picker) and the one audio element that reads them (the player), tied
// to the speech detector's three moments (#748, #758).
// - speech starts: nothing new is read, and the reply playing and the ones
//   queued behind it are cut off and kept;
// - the burst ends, sent as a turn or discarded as not speech: the cut-off
//   sequence comes back in order, then whatever landed meanwhile. Speaking over
//   a reply never loses it (Daniel, #758: "I do want to hear whatever you have
//   got to say, even if I interrupt it"). The reply that was playing restarts if
//   it had played under RESTART_UNDER seconds, and otherwise resumes from about
//   where it stopped;
// - End (close) is the only thing that drops it.
export const RESTART_UNDER = 5;

export const resumeFrom = (at) => (at >= RESTART_UNDER ? at : 0);

export function createReplyReader({ messages = [], onchange }) {
  const picker = createReplyPicker(messages);
  const player = createPlayer({
    urlFor: (id, from) => (from > 0 ? messageSpeechPath(id, { from: Math.floor(from) }) : messageSpeechPath(id)),
    onchange,
  });
  let interrupted = [];
  const read = (ids) => ids.forEach((id) => player.enqueue(id));
  const resume = (current) => {
    const back = interrupted;
    interrupted = [];
    picker.release();
    back.forEach(({ id, at }) => player.enqueue(id, resumeFrom(at)));
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
    },
  };
}
