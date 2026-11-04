import { writable } from 'svelte/store';
import { messageSpeechPath, messageSpeechTextPath } from '@/routes';
import { synthesize as phononSynthesize } from '$lib/phonon-engine';

// Where a resident message's audio comes from (SpeechEngine, jEDyze). The
// server decides the engine per message (the account's choice, the site's
// scope, the resident's plan), and this follows it without second-guessing:
// - phonon: the shared formatter's text is made into speech here, in the
//   browser, and kept as a WAV blob URL per message, so a resume or a replay
//   plays the same audio instead of making it again;
// - elevenlabs: voice mode's streamed speech URL (Messages::SpeechesController),
//   or, for Listen, whatever that surface already does (stored audio);
// - unavailable: a SpeechError with the server's reason, never the other engine.

export class SpeechError extends Error {
  constructor(message, { reason = null, cause } = {}) {
    super(message, { cause });
    this.name = 'SpeechError';
    this.reason = reason;
  }
}

// The open conversation's account engine ('phonon' | 'elevenlabs'), set by
// the chat page from its voice_mode prop, which follows the Account channel.
// The voice panel and Listen stop what the old engine was reading when it
// changes.
export const accountSpeechEngine = writable('phonon');

export async function fetchSpeechText(id, { mode = 'voice_mode', signal, request = fetch } = {}) {
  const response = await request(`${messageSpeechTextPath(id)}?for=${encodeURIComponent(mode)}`, {
    headers: { Accept: 'application/json' },
    credentials: 'same-origin',
    signal,
  });
  if (!response.ok) throw new SpeechError(`This message can't be read aloud (${response.status}).`);
  return response.json();
}

// keep: how many made replies stay playable. Voice mode keeps the last 24;
// Listen keeps every one it made until the page resets it (lib/listen.js),
// because a player on the page may still be holding any of them.
export function createSpeechSource({
  mode = 'voice_mode',
  keep: limit = 24,
  fetchText = fetchSpeechText,
  synthesize = phononSynthesize,
  streamUrl = (id) => messageSpeechPath(id),
  createUrl = (blob) => URL.createObjectURL(blob),
  revokeUrl = (url) => URL.revokeObjectURL(url),
} = {}) {
  const made = new Map(); // id -> blob URL, newest last
  let closed = false;

  // A reply made twice (an interrupted synthesis that finished anyway) keeps
  // the URL already handed out, and the new one is released at once.
  function keep(id, url) {
    if (made.has(id)) {
      revokeUrl(url);
      return made.get(id);
    }
    made.set(id, url);
    while (made.size > limit) {
      const [oldest, oldUrl] = made.entries().next().value;
      made.delete(oldest);
      revokeUrl(oldUrl);
    }
    return url;
  }

  return {
    // Resolves to { url, engine }. Rejects with SpeechError (or an AbortError).
    async resolve(id, { signal } = {}) {
      if (closed) throw new SpeechError('Stopped.');
      if (made.has(id)) return { url: made.get(id), engine: 'phonon' };
      const answer = await fetchText(id, { mode, signal });
      if (!answer.available)
        throw new SpeechError(answer.message || "This resident can't be read aloud just now.", {
          reason: answer.reason,
        });
      if (answer.engine === 'elevenlabs')
        return { url: mode === 'voice_mode' ? streamUrl(id) : null, engine: 'elevenlabs' };
      if (!answer.text) throw new SpeechError('There is nothing in this message to read aloud.', { reason: 'empty' });
      const { blob } = await synthesize(answer.text, { voice: answer.voice, signal });
      if (closed) throw new SpeechError('Stopped.');
      return { url: keep(id, createUrl(blob)), engine: 'phonon' };
    },
    has(id) {
      return made.has(id);
    },
    close() {
      closed = true;
      for (const url of made.values()) revokeUrl(url);
      made.clear();
    },
  };
}
