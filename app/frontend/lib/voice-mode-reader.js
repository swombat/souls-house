import { createPlayer } from '$lib/voice-mode-playback';
import { createReplyPicker } from '$lib/voice-mode-replies';
import { messageSpeechPath } from '@/routes';

// The reply side of voice mode (VoiceModePanel): which replies are read
// (the picker) and the one audio element that reads them (the player), tied
// to the speech detector's three moments (#748).
// - speech starts: nothing new is read, and the reply playing and the ones
//   queued behind it are cut off and kept;
// - the burst is discarded (not speech): that cut-off sequence is read again,
//   the playing reply from its start, then whatever landed during the burst;
// - the turn is committed: the cut-off sequence is dropped and everything on
//   the page then is superseded.
export function createReplyReader({ messages = [], onchange }) {
  const picker = createReplyPicker(messages);
  const player = createPlayer({ urlFor: (id) => messageSpeechPath(id), onchange });
  let interrupted = [];
  const read = (ids) => ids.forEach((id) => player.enqueue(id));

  return {
    take(current) {
      read(picker.take(current));
    },
    speechStarted() {
      picker.hold();
      interrupted = [...interrupted, ...player.interrupt()];
    },
    discarded(current) {
      const resume = interrupted;
      interrupted = [];
      picker.discard();
      read(resume);
      read(picker.take(current));
    },
    committed(current) {
      interrupted = [];
      picker.commit(current);
    },
    // Terminal: once End begins nothing is read during its drain.
    close() {
      player.close();
    },
  };
}
