import { createEngineReader } from '$lib/voice-mode-reader';
import { unlockAudio } from '$lib/voice-mode-playback';
import { voiceModeOpen } from '$lib/voice-mode-open';

// "Read replies aloud" for one conversation (eVvVEe): the speaker in the
// conversation header. While it is on, every resident message that finishes
// arriving after it was switched on is read once, in page order, with the
// account's engine. No microphone and no speech detector: this is voice
// mode's reader (createEngineReader: the reply picker and the one player)
// without the hold. Daniel, 11 Nov: outdoors, street noise kept the detector
// "hearing" and nothing was read.
//
// - The reader's boundary is the moment it is made, so switching on makes a
//   fresh one and earlier history is never read.
// - Switching on is the tap that lets a phone play later replies: it starts
//   the shared audio element on a silent clip (unlockAudio). If the browser
//   refuses a reply anyway, the replies it refused are kept and the toggle
//   shows a separate "Tap to play" control beside it; that tap unlocks again
//   and asks for them. The speaker itself always switches on and off, so
//   stopping stays one tap away even while something is waiting (Mira's
//   review of #888).
// - Voice mode owns reading while its panel is open: the reader here is
//   closed (paused), and a fresh one is made when the panel closes, so what
//   voice mode read is not read twice and reading resumes from that moment.
// - Switching off stops what is playing at once.
// - The choice is per conversation and per device (localStorage), so it
//   survives a reload; leaving the page closes the reader.
//   A browser whose storage policy forbids localStorage throws on the bare
//   property read; then the choice lasts for this page only.

const key = (chatId) => `souls-house.read-aloud.${chatId}`;

export function pageStorage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export function readAloudStored(chatId, storage = pageStorage()) {
  try {
    return Boolean(chatId) && storage?.getItem(key(chatId)) === 'on';
  } catch {
    return false;
  }
}

function remember(chatId, on, storage) {
  try {
    if (on) storage?.setItem(key(chatId), 'on');
    else storage?.removeItem(key(chatId));
  } catch {
    // Private mode or a full store: the toggle still works for this page.
  }
}

// state: { on, paused, speaking (message id or null), blocked, note }
export function createReadAloud({
  chatId,
  messages,
  onstate,
  voiceOpen = voiceModeOpen,
  createReader = createEngineReader,
  unlock = unlockAudio,
  storage = pageStorage(),
}) {
  let on = readAloudStored(chatId, storage);
  let paused = false;
  let speaking = null;
  let blocked = [];
  let note = '';
  let reader = null;
  let destroyed = false;

  const state = () => ({ on, paused, speaking, blocked: blocked.length > 0, note });
  const emit = () => onstate?.(state());

  function start() {
    if (reader || !on || paused || destroyed) return;
    reader = createReader(messages, {
      onchange(id) {
        speaking = id;
        if (id) note = '';
        emit();
      },
      onnote(text, { id, error } = {}) {
        if (error?.name === 'NotAllowedError') {
          if (id && !blocked.includes(id)) blocked = [...blocked, id];
        } else {
          note = text;
        }
        emit();
      },
    });
    reader.take(messages());
  }

  function stop() {
    reader?.close();
    reader = null;
    speaking = null;
    blocked = [];
  }

  const unsubscribe = voiceOpen.subscribe((open) => {
    paused = Boolean(open);
    if (paused) stop();
    else start();
    emit();
  });

  return {
    get state() {
      return state();
    },
    take(list) {
      reader?.take(list);
    },
    // "Tap to play": call from inside the tap. Asks again for the replies
    // the browser refused; never switches reading off.
    playBlocked() {
      if (destroyed || !on || paused || !reader || !blocked.length) return;
      if (!speaking) unlock();
      const ids = blocked;
      blocked = [];
      ids.forEach((id) => reader.replay(id));
      emit();
    },
    // The speaker: call from inside the tap. Always switches on or off.
    toggle() {
      if (destroyed) return;
      on = !on;
      remember(chatId, on, storage);
      note = '';
      if (on) {
        if (!paused) unlock();
        start();
      } else {
        stop();
      }
      emit();
    },
    destroy() {
      destroyed = true;
      unsubscribe();
      stop();
    },
  };
}
