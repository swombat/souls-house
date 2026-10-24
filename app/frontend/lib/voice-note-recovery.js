// A chat voice note whose transcription failed (#453). The server keeps the
// recording; this module remembers where it is so a reload can still offer
// "Retry transcription", and reads the server's answers honestly.
//
// Where the recording is:
// - saved: the server stored it and said so (audio_signed_id). Retry sends the
//   signed id; a reload restores it from localStorage until it expires.
// - unconfirmed: the upload may or may not have been stored (the connection
//   dropped, or a proxy answered instead of the app). The bytes are kept in the
//   tab and a retry uploads them again.
// - unsaved: the server said nothing was stored. The bytes are in the tab only.
// - gone: the server no longer has it (discarded, expired, or sent). Terminal.
// Nothing here sends a message: a successful retry only returns text.

const PREFIX = 'voice-note-recovery:v1:';

function browserStorage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export function recoveryKey({ userId, accountId, chatId }) {
  return `${PREFIX}${userId}:${accountId}:${chatId || 'new'}`;
}

// Returns true only if the reference was written and reads back. A false here
// means a reload would lose it, so the caller keeps its leave warning.
export function saveRecovery(scope, { signedId, error, expiresAt }, storage = browserStorage()) {
  if (!storage || !signedId) return false;
  const key = recoveryKey(scope);
  const value = JSON.stringify({ signedId, error: error || '', expiresAt: expiresAt || null });
  try {
    storage.setItem(key, value);
    return storage.getItem(key) === value;
  } catch {
    return false;
  }
}

// { signedId, error, expiresAt, expired } or null. Corrupt entries are removed.
export function loadRecovery(scope, { storage = browserStorage(), now = Date.now() } = {}) {
  if (!storage) return null;
  const key = recoveryKey(scope);
  let raw;
  try {
    raw = storage.getItem(key);
  } catch {
    return null;
  }
  if (!raw) return null;
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value.signedId !== 'string' || !value.signedId) throw new Error('corrupt');
    const expiry = value.expiresAt ? Date.parse(value.expiresAt) : NaN;
    return {
      signedId: value.signedId,
      error: typeof value.error === 'string' ? value.error : '',
      expiresAt: Number.isFinite(expiry) ? value.expiresAt : null,
      expired: Number.isFinite(expiry) && expiry <= now,
    };
  } catch {
    clearRecovery(scope, storage);
    return null;
  }
}

export function clearRecovery(scope, storage = browserStorage()) {
  try {
    storage?.removeItem(recoveryKey(scope));
  } catch {
    // Nothing to do: an entry we cannot remove is ignored once the server says it is gone.
  }
}

// Turns a fetch Response (or a thrown fetch) into what the recording is now.
// `retrying` is true when the request named a saved recording by signed id.
export async function readTranscription(response, { retrying = false } = {}) {
  if (!response) {
    return {
      ok: false,
      saved: retrying ? 'saved' : 'unconfirmed',
      error: retrying
        ? 'Could not reach the server. Your recording is still saved.'
        : 'Could not reach the server, so the save is not confirmed. The recording is kept in this tab.',
    };
  }

  let data = null;
  try {
    // Read as text so a proxy's HTML error page cannot throw past us.
    data = typeof response.text === 'function' ? JSON.parse(await response.text()) : await response.json();
  } catch {
    data = null;
  }

  if (response.ok && data?.text) {
    return { ok: true, text: data.text, signedId: data.audio_signed_id || null };
  }

  if (data && typeof data === 'object' && 'saved' in data) {
    if (response.status === 404)
      return { ok: false, saved: 'gone', error: data.error || 'That recording is no longer available.' };
    if (data.saved === true) {
      return {
        ok: false,
        saved: 'saved',
        signedId: data.audio_signed_id,
        expiresAt: data.expires_at || null,
        error: data.error || 'Transcription failed',
        retryable: data.retryable !== false,
      };
    }
    return {
      ok: false,
      saved: 'unsaved',
      error: data.error || 'The recording could not be saved.',
      retryable: data.retryable !== false,
    };
  }

  // An answer that is not the app's (a proxy's 413/502/504, or HTML): the app
  // may still have stored the upload, so do not claim either way.
  if (retrying) {
    return {
      ok: false,
      saved: 'saved',
      error: `Transcription failed (HTTP ${response.status}). Your recording is still saved.`,
    };
  }
  if (response.status === 413) {
    return { ok: false, saved: 'unsaved', error: 'The recording is too large to upload.', retryable: false };
  }
  return {
    ok: false,
    saved: 'unconfirmed',
    error: `Transcription failed (HTTP ${response.status}). The save is not confirmed; the recording is kept in this tab.`,
  };
}

export function expiryLabel(expiresAt, locale) {
  const date = expiresAt ? new Date(expiresAt) : null;
  if (!date || Number.isNaN(date.getTime())) return '';
  return date.toLocaleDateString(locale, { weekday: 'short', day: 'numeric', month: 'short' });
}

export function transcriptionPath({ accountId, chatId }) {
  return chatId ? `/accounts/${accountId}/chats/${chatId}/transcription` : `/accounts/${accountId}/chats/transcription`;
}

// Resolves to the Response, or null when the request never got an answer.
export function transcriptionRequest(where, method, formData) {
  return fetch(transcriptionPath(where), {
    method,
    headers: {
      'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
      Accept: 'application/json',
    },
    credentials: 'same-origin',
    body: formData,
  }).catch(() => null);
}

export function uploadForm(blob, mimeType) {
  const ext = mimeType.includes('mp4') ? 'mp4' : 'webm';
  const formData = new FormData();
  formData.append('audio', blob, `recording.${ext}`);
  return formData;
}

export function signedIdForm(signedId) {
  const formData = new FormData();
  formData.append('audio_signed_id', signedId);
  return formData;
}

// The composer text after a retried transcript lands: the transcript alone in an empty
// composer, unchanged if it already says exactly that, otherwise after what was typed.
export function withTranscript(current, text) {
  const typed = (current || '').trimEnd();
  if (!typed.trim()) return text;
  if (typed.trim() === text.trim()) return current;
  return `${typed}\n\n${text}`;
}
