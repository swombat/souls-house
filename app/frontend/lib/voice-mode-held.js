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

// One submission identity per spoken turn, for its whole life (#797): the
// house returns the first message to a retry that carries it, so a POST that
// committed but lost its response is never posted twice. The format matches
// Message#client_message_id (8-64 of A-Z a-z 0-9 _ -).
export function newTurnIdentity() {
  const random = Math.random().toString(36).slice(2, 12);
  return `vm-${Date.now().toString(36)}-${random}`;
}

export function heldStorageKey(chatId) {
  return `voice-mode-held:${chatId}`;
}

// Identities a queue has let go of (sent, discarded, no words after all),
// under `<key>:finished`. A turn's identity is unique, so once any panel has
// finished it, no other panel sends it or writes it back: Discard in a
// reopened panel is final even while the panel that ended is still finishing
// that turn (Mira, #797 review).
const FINISHED_KEEP = 100;

function readFinished(storage, key) {
  try {
    const list = JSON.parse(storage?.getItem(`${key}:finished`) || '[]');
    return new Set(Array.isArray(list) ? list : []);
  } catch {
    return new Set();
  }
}

function markFinished(storage, key, clientMessageId) {
  if (!clientMessageId) return;
  try {
    const list = [...readFinished(storage, key)].filter((id) => id !== clientMessageId);
    list.push(clientMessageId);
    storage?.setItem(`${key}:finished`, JSON.stringify(list.slice(-FINISHED_KEEP)));
  } catch {
    // storage unavailable: this panel still drops the turn
  }
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
  // Every identity this panel has held, so saving merges with what another
  // panel (an earlier one, still finishing after End) keeps under the same key
  // rather than overwriting it.
  const seen = new Set();
  let items = readStored(storage, key).map((item) => ({
    id: `held-${(nextId += 1)}`,
    clientMessageId: item.clientMessageId || newTurnIdentity(),
    text: item.text,
    signedId: item.signedId || null,
    samples: null,
    durationMs: item.durationMs || 0,
    error: item.error || 'Not sent before the page was reloaded.',
    state: 'failed',
    autoRetried: false,
  }));
  let draining = null;

  items.forEach((item) => seen.add(item.clientMessageId));

  function persist() {
    try {
      const finished = readFinished(storage, key);
      items = items.filter((item) => !finished.has(item.clientMessageId));
      const others = readStored(storage, key).filter(
        (item) => !seen.has(item.clientMessageId) && !finished.has(item.clientMessageId)
      );
      const mine = items
        .filter((item) => item.text?.trim())
        .map(({ clientMessageId, text, signedId, durationMs, error }) => ({
          clientMessageId,
          text,
          signedId,
          durationMs,
          error,
        }));
      const stored = [...others, ...mine];
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
  function hold({
    text = '',
    signedId = null,
    samples = null,
    durationMs = 0,
    error = '',
    state = 'failed',
    clientMessageId = newTurnIdentity(),
  }) {
    const item = {
      id: `held-${(nextId += 1)}`,
      clientMessageId,
      text,
      signedId,
      samples,
      durationMs,
      error,
      state,
      autoRetried: false,
    };
    seen.add(clientMessageId);
    items.push(item);
    changed();
    return item.id;
  }

  // Fills in what a turn held at End learned afterwards (its clean text).
  function update(id, fields) {
    const item = items.find((other) => other.id === id);
    if (!item) return;
    Object.assign(item, fields);
    changed();
  }

  // Lets a turn go for good, here and in every panel sharing the key.
  function discard(id) {
    const item = items.find((other) => other.id === id);
    if (item) markFinished(storage, key, item.clientMessageId);
    const before = items.length;
    items = items.filter((item) => item.id !== id);
    if (items.length !== before) changed();
  }

  // A turn some panel has already sent or let go: not to be sent again.
  function finished(clientMessageId) {
    return Boolean(clientMessageId) && readFinished(storage, key).has(clientMessageId);
  }

  // A turn this panel sent without holding it: recorded as finished too, so a
  // copy another panel holds is not sent a second time.
  function finish(clientMessageId) {
    markFinished(storage, key, clientMessageId);
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
        if (finished(item.clientMessageId)) {
          // Another panel sent or discarded it meanwhile.
          items = items.filter((other) => other !== item);
          changed();
          continue;
        }
        if (result?.ok) {
          markFinished(storage, key, item.clientMessageId);
          items = items.filter((other) => other !== item);
          changed();
          continue;
        }
        // What the attempt recovered (a clean transcript, a kept recording) is
        // kept whatever happened next (Tom/Mira, #797 review).
        if (result?.text) item.text = result.text;
        if (result?.signedId) item.signedId = result.signedId;
        if (result?.fatal) {
          item.state = 'failed';
          item.error = result.error || item.error;
          changed();
          break;
        }
        if (result?.dropped) {
          // Transcribed again and there were no words after all.
          markFinished(storage, key, item.clientMessageId);
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
    update,
    discard,
    finished,
    finish,
    drain,
    // The live turn object, for deliver() to read samples from.
    item: (id) => items.find((item) => item.id === id) || null,
  };
}
