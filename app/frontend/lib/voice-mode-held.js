// Turns that were heard but have not reached the house (jMapOj). Before this, a
// turn that failed after its caption showed (upload, clean transcript, post,
// timeout, offline) went to the console and was gone: Daniel's "five, six,
// seven, eight" was on screen and never arrived (jNwAdJ YVvdnw).
//
// A held turn stays in the panel with what is known of it: its text when there
// is one, its recording's samples in memory when there is no text yet (so the
// clean transcript can be asked for again), and why it is held. Order is kept:
// once a turn is held, every later turn waits behind it, so the conversation
// never receives a reply-worthy turn before the one said ahead of it. drain()
// sends from the front and stops at the first failure.
//
// The text-bearing turns are mirrored to sessionStorage (cheap, and survives a
// reload of the same tab); samples are not, so an untranscribed turn is lost
// on reload, and says so in the panel while it is held.

let nextId = 0;

export function heldStorageKey(chatId) {
  return `voice-mode-held:${chatId}`;
}

function readStored(storage, key) {
  try {
    const raw = storage?.getItem(key);
    const list = raw ? JSON.parse(raw) : [];
    return Array.isArray(list) ? list.filter((item) => typeof item?.text === 'string' && item.text.trim()) : [];
  } catch {
    return [];
  }
}

// deliver(turn) sends one held turn and resolves to { ok, error, fatal }.
// fatal stops the whole queue without marking the turn (the mode was switched
// off). onchange(list) fires with a fresh copy after every change.
export function createHeldTurns({ storage = globalThis.sessionStorage, key, deliver, onchange } = {}) {
  let items = readStored(storage, key).map((item) => ({
    id: `held-${(nextId += 1)}`,
    text: item.text,
    signedId: item.signedId || null,
    samples: null,
    durationMs: item.durationMs || 0,
    error: item.error || 'Not sent before the page was reloaded.',
    state: 'failed',
    autoRetried: false,
  }));
  let draining = null;

  function persist() {
    try {
      const stored = items
        .filter((item) => item.text?.trim())
        .map(({ text, signedId, durationMs, error }) => ({ text, signedId, durationMs, error }));
      if (stored.length) storage?.setItem(key, JSON.stringify(stored));
      else storage?.removeItem(key);
    } catch {
      // storage full or unavailable: the panel still holds the turn
    }
  }

  function changed() {
    persist();
    onchange?.(list());
  }

  function list() {
    return items.map((item, index) => ({
      id: item.id,
      text: item.text,
      error: item.error,
      state: index === 0 ? item.state : 'waiting',
      transcribed: Boolean(item.text?.trim()),
      durationMs: item.durationMs,
    }));
  }

  // Keeps a turn. state 'failed' carries why; 'waiting' means it was fine but
  // arrived behind a held turn.
  function hold({ text = '', signedId = null, samples = null, durationMs = 0, error = '', state = 'failed' }) {
    const item = { id: `held-${(nextId += 1)}`, text, signedId, samples, durationMs, error, state, autoRetried: false };
    items.push(item);
    changed();
    return item.id;
  }

  function discard(id) {
    const before = items.length;
    items = items.filter((item) => item.id !== id);
    if (items.length !== before) changed();
  }

  // Sends from the front, in order, until one fails. auto: an automatic retry
  // (the page came back, the network came back, a reload): each turn gets one,
  // after which only Retry sends it, so a turn that cannot go is not hammered.
  function drain({ auto = false } = {}) {
    if (draining) return draining;
    draining = (async () => {
      while (items.length) {
        const item = items[0];
        if (auto && item.state === 'failed' && item.autoRetried) break;
        if (auto) item.autoRetried = true;
        item.state = 'retrying';
        changed();
        let result;
        try {
          result = await deliver(item);
        } catch (error) {
          result = { ok: false, error: error?.message || 'Could not send what you said.' };
        }
        if (!items.includes(item)) continue; // discarded while it was being sent
        if (result?.ok) {
          items = items.filter((other) => other !== item);
          changed();
          continue;
        }
        if (result?.fatal) {
          item.state = 'failed';
          item.error = result.error || item.error;
          changed();
          break;
        }
        if (result?.text !== undefined) item.text = result.text;
        if (result?.signedId) item.signedId = result.signedId;
        if (result?.dropped) {
          // Transcribed again and there were no words after all.
          items = items.filter((other) => other !== item);
          changed();
          continue;
        }
        item.state = 'failed';
        item.error = result?.error || 'Could not send what you said.';
        changed();
        break;
      }
    })().finally(() => (draining = null));
    return draining;
  }

  return {
    get size() {
      return items.length;
    },
    get draining() {
      return Boolean(draining);
    },
    list,
    hold,
    discard,
    drain,
    // The live turn object, for deliver() to read samples from.
    item: (id) => items.find((item) => item.id === id) || null,
  };
}
